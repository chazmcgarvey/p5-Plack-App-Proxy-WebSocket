package Plack::App::Proxy::WebSocket;
# ABSTRACT: proxy HTTP and WebSocket connections

use warnings FATAL => 'all';
use strict;

use AnyEvent::Handle;
use AnyEvent::Socket;
use HTTP::Request;
use HTTP::Response;
use Plack::Request;
use URI;

use parent 'Plack::App::Proxy';

=head1 SYNOPSIS

    use Plack::App::Proxy::WebSocket;
    use Plack::Builder;

    builder {
        mount "/socket.io" => Plack::App::Proxy::WebSocket->new(
            remote               => "http://localhost:9000/socket.io",
            preserve_host_header => 1,
        )->to_app;
    };

=head1 DESCRIPTION

This is a subclass of L<Plack::App::Proxy> that adds support for proxying
WebSocket connections.  It has no extra dependencies or configuration options
beyond what L<Plack::App::Proxy> requires or provides, so it may be an easy
drop-in replacement.  Read the documentation of that module for advanced usage
not covered by the L<SYNOPSIS>.

This subclass necessarily requires extra L<PSGI> server features in order to
work.  The server must support C<psgi.streaming> and C<psgix.io>.  It is also
highly recommended to choose a C<psgi.nonblocking> server, though that isn't
strictly required; performance may suffer greatly without it.  L<Twiggy> is an
excellent choice for this application.

This module is B<EXPERIMENTAL>.  I use it in development and it works
swimmingly for me, but it is completely untested in production scenarios.

=head1 CAVEATS

Some servers (e.g. L<Starman>) ignore the C<Connection> HTTP response header
and use their own values, but WebSocket clients expect the value of that
header to be C<Upgrade>.  This module cannot work on such servers.  Your best
bet is to use a non-blocking server like L<Twiggy> that doesn't mess with the
C<Connection> header.

=cut

sub call {
    my ($self, $env) = @_;
    my $req = Plack::Request->new($env);

    # detect the websocket handshake or just proxy as usual
    lc($req->header('Upgrade') || "") eq 'websocket' or return $self->SUPER::call($env);

    $env->{'psgi.streaming'} or die "Plack server support for psgi.streaming is required";
    my $client_fh = $env->{'psgix.io'} or die "Plack server support for the psgix.io extension is required";

    my $url = $self->build_url_from_env($env) or return [502, [], ["Bad Gateway"]];
    my $uri = URI->new($url);

    sub {
        my $res = shift;

        # set up an event loop if the server is blocking
        my $cv;
        unless ($env->{'psgi.nonblocking'}) {
            $env->{'psgi.errors'}->print("Plack server support for psgi.nonblocking is highly recommended.\n");
            $cv = AE::cv;
        }

        tcp_connect $uri->host, $uri->port, sub {
            my $server_fh = shift;

            # return 502 if connection to server fails
            unless ($server_fh) {
                $res->([502, [], ["Bad Gateway"]]);
                $cv->send if $cv;
                return;
            }

            my $client = AnyEvent::Handle->new(fh => $client_fh);
            my $server = AnyEvent::Handle->new(fh => $server_fh);

            # forward request from the client, modifying the host and origin
            my $headers = $req->headers->clone;
            my $host = $uri->host_port;
            $headers->header(Host => $host, Origin => "http://$host");
            my $hs = HTTP::Request->new('GET', $uri->path, $headers);
            $hs->protocol($req->protocol);
            $server->push_write($hs->as_string);

            my $buffer = "";
            my $writer;

            # buffer the exchange between the client and server
            $client->on_read(sub {
                my $hdl = shift;
                my $buf = delete $hdl->{rbuf};
                $server->push_write($buf);
            });
            $server->on_read(sub {
                my $hdl = shift;
                my $buf = delete $hdl->{rbuf};

                if ($writer) {
                    $writer->write($buf);
                    return;
                }

                if (($buffer .= $buf) =~ s/^(.+\r?\n\r?\n)//s) {
                    my $http = HTTP::Response->parse($1);
                    my @headers;
                    $http->headers->remove_header('Status');
                    $http->headers->scan(sub { push @headers, @_ });
                    $writer = $res->([$http->code, [@headers]]);
                    $writer->write($buffer) if $buffer;
                    $buffer = undef;
                }
            });

            # shut down the sockets and exit the loop if an error occurs
            $client->on_error(sub {
                $client->destroy;
                $server->push_shutdown;
                $cv->send if $cv;
                $writer->close if $writer;
            });
            $server->on_error(sub {
                $server->destroy;
                # get the client handle's attention
                $writer->close;
            });
        };

        $cv->recv if $cv;
    };
};

1;
