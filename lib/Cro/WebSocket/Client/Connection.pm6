use Cro;
use Cro::TCP;
use Cro::WebSocket::FrameParser;
use Cro::WebSocket::FrameSerializer;
use Cro::WebSocket::Internal;
use Cro::WebSocket::Message;
use Cro::WebSocket::MessageParser;
use Cro::WebSocket::MessageSerializer;

my class PromiseFactory {
    has @.promises;

    method get-new(--> Promise) {
        my $p = Promise.new;
        @!promises.push: $p;
        $p;
    }

    method reset() {
        @!promises.map({.keep});
        @!promises = ();
    }
}

class Cro::WebSocket::Client::Connection {
    has Supply $.in;
    has Supplier $.out;
    has Supplier $.sender;
    has Supply $.receiver;
    has Promise $.closer;
    has PromiseFactory $.pong;
    has Bool $.closed;

    method new(:$in, :$out, :$body-parsers, :$body-serializers) {
        my $sender = Supplier::Preserving.new;
        my $receiver = Supplier::Preserving.new;
        my $closer = Promise.new;
        my $pong = PromiseFactory.new;
        my $closed = False;

        my @before;
        unless $body-serializers === Any {
            unshift @before, SetBodySerializers.new(:$body-serializers);
        }
        my @after;
        unless $body-parsers === Any {
            push @after, SetBodyParsers.new(:$body-parsers);
        }

        my $pp-in = Cro.compose(
            Cro::WebSocket::FrameParser.new(:!mask-required),
            Cro::WebSocket::MessageParser.new,
            |@after
        ).transformer($in.map(-> $data { Cro::TCP::Message.new(:$data) }));

        my $pp-out = Cro.compose(
            |@before,
            Cro::WebSocket::MessageSerializer.new,
            Cro::WebSocket::FrameSerializer.new(:mask)
        ).transformer($sender.Supply);

        my Cro::WebSocket::Client::Connection $instance = self.bless:
            :$in, :$out, :$sender, receiver => $receiver.Supply, :$closer, :$pong, :$closed;

        $pp-in.tap:
            {
                if .is-data {
                    $receiver.emit: $_;
                } else {
                    when $_.opcode == Cro::WebSocket::Message::Ping {
                        my $body-byte-stream = $_.body-byte-stream;
                        my $m = Cro::WebSocket::Message.new(opcode => Cro::WebSocket::Message::Pong,
                                                            fragmented => False,
                                                            :$body-byte-stream);
                        $sender.emit: $m;
                    }
                    when $_.opcode == Cro::WebSocket::Message::Pong {
                        $pong.reset;
                    }
                    when $_.opcode == Cro::WebSocket::Message::Close {
                        .keep($_) with $instance.closer;
                        $instance.close(1000);
                        $receiver.done;
                    }
                }
            },
            done => {
                $instance!set-closed();
            },
            quit => {
                $instance!set-closed();
                $receiver.quit($_);
            };
        $pp-out.tap: { $out.emit: .data }, quit => { $out.quit($_) };

        $instance;
    }

    method !set-closed(--> Nil) {
        $!closed = True;
    }

    method messages(--> Supply) {
        $!receiver;
    }

    multi method send(Cro::WebSocket::Message $m --> Nil) {
        die if $!closed;
        $!sender.emit($m);
    }
    multi method send($m) {
        self.send(Cro::WebSocket::Message.new($m));
    }

    method close($code = 1000, :$timeout --> Promise) {
        # Double closing has no effect;
        return if $!closed;
        $!closed = True;
        my $p = Promise.new;
        my &body = -> $_ { supply { emit Blob.new($_ +& 0xFF, ($_ +> 8) +& 0xFF); } };

        start {
            my $message = Cro::WebSocket::Message.new(opcode => Cro::WebSocket::Message::Close,
                                                      fragmented => False,
                                                      body-byte-stream => &body($code));
            my $real-timeout = $timeout // 2;
            if $real-timeout == False || $real-timeout == 0 {
                $!sender.emit: $message;
                $!sender.done;
                $p.keep($message);
            } else {
                $!sender.emit: $message;
                $!sender.done;
                await Promise.anyof(Promise.in($real-timeout), $!closer);
                if $!closer.status == Kept {
                    $p.keep($!closer.result);
                } else {
                    my $close-m = Cro::WebSocket::Message.new(opcode => Cro::WebSocket::Message::Close,
                                                              fragmented => False,
                                                              body-byte-stream => &body(1006));
                    $p.break($close-m);
                }
            }
        }
        $p;
    }

    method ping($data?, Int :$timeout --> Promise) {
        my $p = $!pong.get-new;

        with $timeout {
            Promise.in($timeout).then: {
                unless $p.status ~~ Kept {
                    $p.break;
                }
            }
        }

        $!sender.emit(Cro::WebSocket::Message.new(
            opcode => Cro::WebSocket::Message::Ping,
            fragmented => False,
            body-byte-stream => supply {
                emit ($data ?? Blob.new($data.encode) !! Blob.new);
            }));

        $p;
    }
}
