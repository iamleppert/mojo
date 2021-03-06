#!/usr/bin/env perl
use Mojo::Base -strict;

# Disable Bonjour, IPv6 and libev
BEGIN {
  $ENV{MOJO_NO_BONJOUR} = $ENV{MOJO_NO_IPV6} = 1;
  $ENV{MOJO_IOWATCHER} = 'Mojo::IOWatcher';
}

use Test::More tests => 44;

# "I can't believe it! Reading and writing actually paid off!"
use IO::Socket::INET;
use Mojo::IOLoop;
use Mojo::UserAgent;
use Mojolicious::Lite;

# User agent
my $ua = app->ua;

# Loop
my $loop = Mojo::IOLoop->singleton;

# Silence
app->log->level('fatal');

# Avoid exception template
app->renderer->root(app->home->rel_dir('public'));

# GET /link
get '/link' => sub {
  my $self = shift;
  $self->render(text => $self->url_for('index')->to_abs);
};

# WebSocket /
my $flag;
websocket '/' => sub {
  my $self = shift;
  $self->on_finish(sub { $flag += 4 });
  $self->on_message(
    sub {
      my ($self, $message) = @_;
      my $url = $self->url_for->to_abs;
      $self->send_message("${message}test2$url");
      $flag = 20;
    }
  );
} => 'index';

# GET /something/else
get '/something/else' => sub {
  my $self = shift;
  my $timeout =
    Mojo::IOLoop->singleton->connection_timeout($self->tx->connection);
  $self->render(text => "${timeout}failed!");
};

# WebSocket /socket
websocket '/socket' => sub {
  my $self = shift;
  $self->send_message(
    $self->req->headers->host,
    sub {
      my $self = shift;
      $self->send_message(
        Mojo::IOLoop->connection_timeout($self->tx->connection));
      $self->finish;
    }
  );
};

# WebSocket /early_start
websocket '/early_start' => sub {
  my $self = shift;
  $self->send_message('test1');
  $self->on_message(
    sub {
      my ($self, $message) = @_;
      $self->send_message("${message}test2");
      $self->finish;
    }
  );
};

# WebSocket /denied
my ($handshake, $denied) = 0;
websocket '/denied' => sub {
  my $self = shift;
  $self->tx->handshake->on(finish => sub { $handshake += 2 });
  $self->on_finish(sub { $denied += 1 });
  $self->render(text => 'denied', status => 403);
};

# WebSocket /subreq
my $subreq = 0;
websocket '/subreq' => sub {
  my $self = shift;
  $self->ua->websocket(
    '/echo' => sub {
      my $tx = pop;
      $tx->on(
        message => sub {
          my ($tx, $message) = @_;
          $self->send_message($message);
          $tx->finish;
          $self->finish;
        }
      );
      $tx->send_message('test1');
    }
  );
  $self->send_message('test0');
  $self->on_finish(sub { $subreq += 3 });
};

# WebSocket /echo
websocket '/echo' => sub {
  my $self = shift;
  $self->tx->max_websocket_size(500000);
  $self->on_message(
    sub {
      my ($self, $message) = @_;
      $self->send_message($message);
    }
  );
};

# WebSocket /double_echo
my $buffer = '';
websocket '/double_echo' => sub {
  shift->on_message(
    sub {
      my ($self, $message) = @_;
      $self->send_message($message, sub { shift->send_message($message) });
    }
  );
};

# WebSocket /dead
websocket '/dead' => sub { die 'i see dead processes' };

# WebSocket /foo
websocket '/foo' =>
  sub { shift->rendered->res->code('403')->message("i'm a teapot") };

# WebSocket /deadcallback
websocket '/deadcallback' => sub {
  my $self = shift;
  $self->on_message(sub { die 'i see dead callbacks' });
};

# GET /link
my $res = $ua->get('/link')->success;
is $res->code, 200, 'right status';
like $res->body, qr/ws\:\/\/localhost\:\d+\//, 'right content';

# GET /socket (plain HTTP request)
$res = $ua->get('/socket')->res;
is $res->code,   404,           'right status';
like $res->body, qr/Not Found/, 'right content';

# WebSocket /
my $result;
$ua->websocket(
  '/' => sub {
    my $tx = pop;
    $tx->on(finish => sub { $loop->stop });
    $tx->on(
      message => sub {
        my ($tx, $message) = @_;
        $result = $message;
        $tx->finish;
      }
    );
    $tx->send_message('test1');
  }
);
$loop->start;
like $result, qr/test1test2ws\:\/\/localhost\:\d+\//, 'right result';

# WebSocket /something/else (failed websocket connection)
my ($code, $body, $ws);
$ua->websocket(
  '/something/else' => sub {
    my $tx = pop;
    $ws   = $tx->is_websocket;
    $code = $tx->res->code;
    $body = $tx->res->body;
    $loop->stop;
  }
);
$loop->start;
is $ws,   undef, 'not a websocket';
is $code, 426,   'right code';
ok $body =~ /^(\d+)failed!$/, 'right content';
ok $1 < 100, 'right timeout';

# WebSocket /socket (using an already prepared socket)
my $port     = $ua->test_server->port;
my $tx       = $ua->build_websocket_tx('ws://lalala/socket');
my $finished = 0;
$tx->on(finish => sub { $finished++ });
my $socket =
  IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port);
$socket->blocking(0);
$tx->connection($socket);
$result = '';
my ($local, $early);
$ua->start(
  $tx => sub {
    my $tx = pop;
    $early = $finished;
    $tx->on(finish => sub { $loop->stop });
    $tx->on(
      message => sub {
        my ($tx, $message) = @_;
        $tx->finish if length $result;
        $result .= $message;
      }
    );
    $local = $loop->local_info($tx->connection)->{port};
  }
);
$loop->start;
is $finished, 1, 'finish event has been emitted';
is $early,    1, 'finish event has been emitted at the right time';
ok $result =~ /^lalala(\d+)$/, 'right result';
ok $1 > 100, 'right timeout';
ok $local, 'local port';
is $loop->handle($tx->connection), $socket, 'right connection id';

# WebSocket /early_start (server directly sends a message)
my $flag2;
$result = undef;
$ua->websocket(
  '/early_start' => sub {
    my $tx = pop;
    $tx->on(
      finish => sub {
        $flag2 += 5;
        $loop->stop;
      }
    );
    $tx->on(
      message => sub {
        my ($tx, $message) = @_;
        $result = $message;
        $tx->send_message('test3');
        $flag2 = 18;
      }
    );
  }
);
$loop->start;
is $result, 'test3test2', 'right result';
is $flag2,  23,           'finish event has been emitted';

# WebSocket /denied (connection denied)
$code = undef;
$ua->websocket(
  '/denied' => sub {
    $code = pop->res->code;
    $loop->stop;
  }
);
$loop->start;
is $code,      403, 'right status';
is $handshake, 2,   'finished handshake';
is $denied,    1,   'finished websocket';

# WebSocket /subreq
$finished = 0;
($code, $result) = undef;
$ua->websocket(
  '/subreq' => sub {
    my $tx = pop;
    $code   = $tx->res->code;
    $result = '';
    $tx->on(
      message => sub {
        my ($tx, $message) = @_;
        $result .= $message;
        $tx->finish if $message eq 'test1';
      }
    );
    $tx->on(
      finish => sub {
        $finished += 4;
        $loop->timer('0.5' => sub { shift->stop });
      }
    );
  }
);
$loop->start;
is $code,     101,          'right status';
is $result,   'test0test1', 'right result';
is $finished, 4,            'finished client websocket';
is $subreq,   3,            'finished server websocket';

# WebSocket /subreq (non-blocking)
my $running = 2;
my ($code2, $result2);
($code, $result) = undef;
$ua->websocket(
  '/subreq' => sub {
    my $tx = pop;
    $code   = $tx->res->code;
    $result = '';
    $tx->on(
      message => sub {
        my ($tx, $message) = @_;
        $result .= $message;
        $tx->finish and $running-- if $message eq 'test1';
        $loop->timer('0.5' => sub { $loop->stop }) unless $running;
      }
    );
    $tx->on(finish => sub { $finished += 1 });
  }
);
$ua->websocket(
  '/subreq' => sub {
    my $tx = pop;
    $code2   = $tx->res->code;
    $result2 = '';
    $tx->on(
      message => sub {
        my ($tx, $message) = @_;
        $result2 .= $message;
        $tx->finish and $running-- if $message eq 'test1';
        $loop->timer('0.5' => sub { $loop->stop }) unless $running;
      }
    );
    $tx->on(finish => sub { $finished += 2 });
  }
);
$loop->start;
is $code,     101,          'right status';
is $result,   'test0test1', 'right result';
is $code2,    101,          'right status';
is $result2,  'test0test1', 'right result';
is $finished, 7,            'finished client websocket';
is $subreq,   9,            'finished server websocket';

# WebSocket /echo (user agent side drain callback)
$flag2  = undef;
$result = '';
my $counter = 0;
$ua->websocket(
  '/echo' => sub {
    my $tx = pop;
    $tx->on(
      finish => sub {
        $flag2 += 5;
        $loop->stop;
      }
    );
    $tx->on(
      message => sub {
        my ($tx, $message) = @_;
        $result .= $message;
        $tx->finish if ++$counter == 2;
      }
    );
    $flag2 = 20;
    $tx->send_message('hi!', sub { shift->send_message('there!') });
  }
);
$loop->start;
is $result, 'hi!there!', 'right result';
is $flag2,  25,          'finish event has been emitted';

# WebSocket /double_echo (server side drain callback)
$flag2   = undef;
$result  = '';
$counter = 0;
$ua->websocket(
  '/double_echo' => sub {
    my $tx = pop;
    $tx->on(
      finish => sub {
        $flag2 += 5;
        $loop->stop;
      }
    );
    $tx->on(
      message => sub {
        my ($tx, $message) = @_;
        $result .= $message;
        $tx->finish if ++$counter == 2;
      }
    );
    $flag2 = 19;
    $tx->send_message('hi!');
  }
);
$loop->start;
is $result, 'hi!hi!', 'right result';
is $flag2,  24,       'finish event has been emitted';

# WebSocket /dead (dies)
$finished = $code = undef;
my ($websocket, $message);
$ua->websocket(
  '/dead' => sub {
    my $tx = pop;
    $finished  = $tx->is_finished;
    $websocket = $tx->is_websocket;
    $code      = $tx->res->code;
    $message   = $tx->res->message;
    $loop->stop;
  }
);
$loop->start;
is $finished,  1,                       'transaction is finished';
is $websocket, undef,                   'no websocket';
is $code,      500,                     'right status';
is $message,   'Internal Server Error', 'right message';

# WebSocket /foo (forbidden)
($websocket, $code, $message) = undef;
$ua->websocket(
  '/foo' => sub {
    my $tx = pop;
    $websocket = $tx->is_websocket;
    $code      = $tx->res->code;
    $message   = $tx->res->message;
    $loop->stop;
  }
);
$loop->start;
is $websocket, undef,          'no websocket';
is $code,      403,            'right status';
is $message,   "i'm a teapot", 'right message';

# WebSocket /deadcallback (dies in callback)
$ua->websocket(
  '/deadcallback' => sub {
    pop->send_message('test1');
    $loop->stop;
  }
);
$loop->start;

# Server side "finished" callback
is $flag, 24, 'finish event has been emitted';

# WebSocket /echo (16bit length)
$result = undef;
$ua->websocket(
  '/echo' => sub {
    my $tx = pop;
    $tx->on(finish => sub { $loop->stop });
    $tx->on(
      message => sub {
        my ($tx, $message) = @_;
        $result = $message;
        $tx->finish;
      }
    );
    $tx->send_message('hi!' x 100);
  }
);
$loop->start;
is $result, 'hi!' x 100, 'right result';

# WebSocket /echo (64bit length)
$result = undef;
$ua->websocket(
  '/echo' => sub {
    my $tx = pop;
    $tx->max_websocket_size(500000);
    $tx->on(finish => sub { $loop->stop });
    $tx->on(
      message => sub {
        my ($tx, $message) = @_;
        $result = $message;
        $tx->finish;
      }
    );
    $tx->send_message('hi' x 200000);
  }
);
$loop->start;
is $result, 'hi' x 200000, 'right result';
