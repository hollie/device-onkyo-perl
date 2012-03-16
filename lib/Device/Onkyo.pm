use strict;
use warnings;
package Device::Onkyo;

use Carp qw/croak carp/;
use Device::SerialPort qw/:PARAM :STAT 0.07/;
use Fcntl;
use IO::Select;
use Socket;
use Symbol qw(gensym);
use Time::HiRes;

use constant {
  DEBUG => $ENV{DEVICE_ONKYO_DEBUG},
};

# ABSTRACT: Perl module to control Onkyo/Intregra AV equipment

=head1 SYNOPSIS

  my $onkyo = Device::Onkyo->new(device => 'discover');
  $onkyo->power('on'); # switch on

  $onkyo = Device::Onkyo->new(device => '/dev/ttyS0');
  $onkyo->write('PWR01'); # switch on
  while (1) {
    my $message = $onkyo->read();
    print $message, "\n";
  }

  $onkyo = Device::Onkyo->new(device => 'hostname:port');
  $onkyo->write('PWR01'); # switch on

=head1 DESCRIPTION

Module for controlling Onkyo/Intregra AV equipment.

B<IMPORTANT:> This is an early release and the API is still subject to
change. The serial port usage is entirely untested.

=cut

sub new {
  my ($pkg, %p) = @_;
  my $self = bless {
                    _buf => '',
                    _q => [],
                    type => 'eISCP',
                    port => 60128,
                    baud => 9600,
                    discard_timeout => 1,
                    %p
                   }, $pkg;
  unless (exists $p{filehandle}) {
    croak $pkg.q{->new: 'device' parameter is required}
      unless (exists $p{device});
    $self->_open();
  }
  $self;
}

sub baud { shift->{baud} }

sub port { shift->{port} }

sub filehandle { shift->{filehandle} }

sub _open {
  my $self = shift;
  if ($self->{device} =~ m![/\\]!) {
    $self->_open_serial_port(@_);
  } else {
    if ($self->{device} eq 'discover') {
      $self->{device} = $self->discover;
    }
    $self->_open_tcp_port(@_);
  }
}

sub _open_tcp_port {
  my $self = shift;
  my $dev = $self->{device};
  print STDERR "Opening $dev as tcp socket\n" if DEBUG;
  require IO::Socket::INET; import IO::Socket::INET;
  if ($dev =~ s/:(\d+)$//) {
    $self->{port} = $1;
  }
  my $fh = IO::Socket::INET->new($dev.':'.$self->port) or
    croak "TCP connect to '$dev' failed: $!";
  return $self->{filehandle} = $fh;
}

sub _open_serial_port {
  my $self = shift;
  $self->{type} = 'ISCP';
  my $fh = gensym();
  my $s = tie (*$fh, 'Device::SerialPort', $self->{device}) ||
    croak "Could not tie serial port to file handle: $!\n";
  $s->baudrate($self->baud);
  $s->databits(8);
  $s->parity("none");
  $s->stopbits(1);
  $s->datatype("raw");
  $s->write_settings();

  sysopen($fh, $self->{device}, O_RDWR|O_NOCTTY|O_NDELAY) or
    croak "open of '".$self->{device}."' failed: $!\n";
  $fh->autoflush(1);
  return $self->{filehandle} = $fh;
}

sub read {
  my ($self, $timeout) = @_;
  my $res = $self->read_one(\$self->{_buf});
  return $res if (defined $res);
  $self->_discard_buffer_check(\$self->{_buf}) if ($self->{_buf} ne '');
  my $fh = $self->filehandle;
  my $sel = IO::Select->new($fh);
  do {
    my $start = $self->_time_now;
    $sel->can_read($timeout) or return;
    my $bytes = sysread $fh, $self->{_buf}, 2048, length $self->{_buf};
    $self->{_last_read} = $self->_time_now;
    $timeout -= $self->{_last_read} - $start if (defined $timeout);
    croak defined $bytes ? 'closed' : 'error: '.$! unless ($bytes);
    $res = $self->read_one(\$self->{_buf});
    $self->_write_now() if (defined $res);
    return $res if (defined $res);
  } while (1);
}

sub read_one {
  my ($self, $rbuf, $no_write) = @_;
  return unless ($$rbuf);

  print STDERR "rbuf=", _hexdump($$rbuf), "\n" if DEBUG;

  if ($self->{type} eq 'eISCP') {
    my $length = length $$rbuf;
    return unless ($length >= 16);
    my ($magic, $header_size,
        $data_size, $version, $res1, $res2, $res3) = unpack 'a4 N N C4', $$rbuf;
    croak "Unexpected magic: expected 'ISCP', got '$magic'\n"
      unless ($magic eq 'ISCP');
    return unless ($length >= $header_size+$data_size);
    substr $$rbuf, 0, $header_size, '';
    carp(sprintf "Unexpected version: expected '0x01', got '0x%02x'\n",
                 $version) unless ($version == 0x01);
    carp(sprintf "Unexpected header size: expected '0x10', got '0x%02x'\n",
                 $header_size) unless ($header_size == 0x10);
    my $body = substr $$rbuf, 0, $data_size, '';
    my $sd = substr $body, 0, 2, '';
    $body =~ s/[\032\r\n]+$//;
    carp "Unexpected start/destination: expected '!1', got '$sd'\n"
      unless ($sd eq '!1');
    $self->_write_now unless ($no_write);
    return $body;
  } else {
    return unless ($$rbuf =~ s/^(..)(....*?)[\032\r\n]+//);
    my ($sd, $body) = ($1, $2);
    carp "Unexpected start/destination: expected '!1', got '$sd'\n"
      unless ($sd eq '!1');
    $self->_write_now unless ($no_write);
    return $body;
  }
}

sub _time_now {
  Time::HiRes::time
}

# 4953 4350 0000 0010 0000 000b 0100 0000  ISCP............
# 2178 4543 4e51 5354 4e0d 0a              !xECNQSTN\r\n

sub discover {
  my $self = shift;
  my $s;
  socket $s, PF_INET, SOCK_DGRAM, getprotobyname('udp');
  setsockopt $s, SOL_SOCKET, SO_BROADCAST, 1;
  binmode $s;
  bind $s, sockaddr_in(0, inet_aton('0.0.0.0'));
  send($s,
       pack("a* N N N a*",
            'ISCP', 0x10, 0xb, 0x01000000, "!xECNQSTN\r\n"),
       0,
       sockaddr_in($self->port, inet_aton('255.255.255.255')));
  my $sel = IO::Select->new($s);
  $sel->can_read(10) or die;
  my $sender = recv $s, my $buf, 2048, 0;
  croak 'error: '.$! unless (defined $sender);

  my ($port, $addr) = sockaddr_in($sender);
  my $ip = inet_ntoa($addr);
  my $b = $buf;
  my $msg = $self->read_one(\$b, 1); # don't uncork writes
  ($port) = ($msg =~ m!/(\d{5})/../[0-9a-f]{12}!i);
  print STDERR "discovered: $ip:$port (@$msg)\n" if DEBUG;
  $self->{port} = $port;
  return $ip.':'.$port;
}

sub write {
  my ($self, $cmd, $cb) = @_;
  print STDERR "queuing: $cmd\n" if DEBUG;
  my $str = $self->pack($cmd);
  push @{$self->{_q}}, [$str, $cmd, $cb];
  $self->_write_now unless ($self->{_waiting});
  1;
}

sub _write_now {
  my $self = shift;
  my $rec = shift @{$self->{_q}};
  my $wait_rec = delete $self->{_waiting};
  if ($wait_rec) {
    $wait_rec->[1]->() if ($wait_rec->[1]);
  }
  return unless (defined $rec);
  $self->_real_write(@$rec);
  $self->{waiting} = [ $self->_time_now, $rec ];
}

sub _real_write {
  my ($self, $str, $desc, $cb) = @_;
  print STDERR "sending: $desc\n  ", _hexdump($str), "\n" if DEBUG;
  syswrite $self->filehandle, $str, length $str;
}

sub pack {
  my $self = shift;
  my $d = '!1'.$_[0];
  if ($self->{type} eq 'eISCP') {
    # 4953 4350 0000 0010 0000 000a 0100 0000 ISCP............
    # 2131 4d56 4c32 381a 0d0a                !1MVL28...
    # 4953 4350 0000 0010 0000 000a 0100 0000 ISCP............
    # 2131 4d56 4c32 381a 0d0a
    $d .= "\r";
    pack("a* N N N a*",
         'ISCP', 0x10, (length $d), 0x01000000, $d);
  } else {
    $d .= "\r\n";
  }
}

sub canon_command {
  my $str = shift;
  $str =~ tr/A-Z/a-z/;
  $str =~ s/(?:question|query|qstn)/?/g;
  $str =~ s/^master\ //g;
  $str =~ s/volume/vol/g;
  $str =~ s/centre/center/g;
  $str =~ s/up/+/g;
  $str =~ s/down/-/g;
  $str =~ s/\s+//g;
  $str;
}

our %command_map =
  (
   'power on' => 'PWR01',
   'power off' => 'PWR00',
   'power standby' => 'PWR00',
   'power?' => 'PWRQSTN',
   'mute' => 'AMT00',
   'unmute' => 'AMT01',
   'toggle mute' => 'AMTTG',
   'mute?' => 'AMTQSTN',
   'speaker a on' => 'SPA01',
   'speaker a off' => 'SPA00',
   'toggle speaker a' => 'SPAUP',
   'speaker a?' => 'SPAQSTN',
   'speaker b on' => 'SPB01',
   'speaker b off' => 'SPB00',
   'toggle speaker b' => 'SPBUP',
   'speaker b?' => 'SPBQSTN',
   'volume+' => 'MVLUP',
   'volume-' => 'MVLDOWN',
   'volume?' => 'MVLQSTN',

   'front bass+' => 'TFRBUP',
   'front bass-' => 'TFRBDOWN',
   'front treble+' => 'TFRTUP',
   'front treble-' => 'TFRTDOWN',
   'front tone?' => 'TFRQSTN',

   'front wide bass+' => 'TFWBUP',
   'front wide bass-' => 'TFWBDOWN',
   'front wide treble+' => 'TFWTUP',
   'front wide treble-' => 'TFWTDOWN',
   'front wide tone?' => 'TFWQSTN',

   'front high bass+' => 'TFHBUP',
   'front high bass-' => 'TFHBDOWN',
   'front high treble+' => 'TFHTUP',
   'front high treble-' => 'TFHTDOWN',
   'front high tone?' => 'TFHQSTN',

   'center bass+' => 'TCTBUP',
   'center bass-' => 'TCTBDOWN',
   'center treble+' => 'TCTTUP',
   'center treble-' => 'TCTTDOWN',
   'center tone?' => 'TCTQSTN',

   'surround bass+' => 'TSRBUP',
   'surround bass-' => 'TSRBDOWN',
   'surround treble+' => 'TSRTUP',
   'surround treble-' => 'TSRTDOWN',
   'surround tone?' => 'TSRQSTN',

   'surround back bass+' => 'TSBBUP',
   'surround back bass-' => 'TSBBDOWN',
   'surround back treble+' => 'TSBTUP',
   'surround back treble-' => 'TSBTDOWN',
   'surround back tone?' => 'TSBQSTN',

   'subwoofer bass+' => 'TSWBUP',
   'subwoofer bass-' => 'TSWBDOWN',
   'subwoofer treble+' => 'TSWTUP',
   'subwoofer treble-' => 'TSWTDOWN',
   'subwoofer tone?' => 'TSWQSTN',

   'sleep off' => 'SLPOFF',
   'sleep?' => 'SLPQSTN',

   'display0' => 'DIF00',
   'display1' => 'DIF01',
   'display2' => 'DIF02',
   'display3' => 'DIF03',
   'display toggle' => 'DIFTG',
   'display?' => 'DIFQSTN',

   'dimmer bright' => 'DIM00',
   'dimmer dim' => 'DIM01',
   'dimmer dark' => 'DIM02',
   'dimmer off' => 'DIM03',
   'dimmer ledoff' => 'DIM08',
   'dimmer toggle' => 'DIMTG',
   'dimmer?' => 'DIMQSTN',

   'menu key' => 'OSDMENU',
   'up key' => 'OSDUP',
   'down key' => 'OSDDOWN',
   'right key' => 'OSDRIGHT',
   'left key' => 'OSDLEFT',
   'enter key' => 'OSDENTER',
   'exit key' => 'OSDEXIT',
   'audio key' => 'OSDAUDIO',
   'video key' => 'OSDVIDEO',
   'home key' => 'OSDHOME',

#   'memory store' => 'MEMSTR',
#   'memory recall' => 'MEMRCL',
#   'memory lock' => 'MEMLOCK',
#   'memory unlock' => 'MEMUNLK',

  );
foreach my $k (keys %command_map) {
  $command_map{canon_command($k)} = delete $command_map{$k};
}

sub command {
  my ($self, $cmd, $cb) = @_;
  my $canon = canon_command($cmd);
  my $str = $command_map{$canon};
  if (defined $str) {
    $cmd = $str;
  } elsif ($canon =~ /^vol(100|[0-9][0-9]?)%?$/) {
    $cmd = sprintf 'MVL%02x', $1;
  } elsif ($canon =~ /^sleep(90|[0-8][0-9]|[1-9])m\w+?$/) {
    $cmd = sprintf 'SLP%02x', $1;
  } elsif ($cmd !~ /^[A-Z][A-Z][A-Z]/) {
    croak ref($self)."->command: '$cmd' does not match /^[A-Z][A-Z][A-Z]/";
  }
  $self->write($cmd, $cb);
}

sub _hexdump {
  my $s = shift;
  my $r = unpack 'H*', $s;
  $s =~ s/[^ -~]/./g;
  $r.' '.$s;
}

1;
