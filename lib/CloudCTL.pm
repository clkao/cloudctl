package Net::Amazon::EC2::Debug;
use Any::Moose;
extends 'Net::Amazon::EC2';
our $VERSION = '0.1';

has logger => (is => "rw", isa => "Log::Log4perl::Logger");

sub _debug {
    my $self        = shift;
    my $message     = shift;

    if ((grep { defined && length} $self->debug) && $self->debug == 1) {
        $self->logger->debug($message);
    }
}

package CloudCTL;
use strict;
use Net::Amazon::EC2;
use MIME::Base64;
use AnyEvent;
use Log::Log4perl;
use DateTime;
use Time::HiRes 'time';

use Sub::Exporter -setup => {
    exports => [qw(ensure_idp_instance stop_idp_instance get_instance get_instance_by_ami get_image_by_name get_cfg watch_for_instance)]
};

use YAML::Syck qw(LoadFile);
my $config;
my $ec2;

sub init_logging {
    my ($class, $logconf) = @_;

    if (-e $logconf) {
        Log::Log4perl::init_and_watch($logconf, 60);
    }
    else {
        Log::Log4perl->easy_init();
    }
}

sub load {
    my ($class, $file, $name, $debug) = @_;
    logger($name);
    $config = LoadFile($file);
    if ($debug) {
        $ec2 = Net::Amazon::EC2::Debug->new( 
            debug => 1,
            AWSAccessKeyId => $config->{key},
            SecretAccessKey => $config->{secret},
            region => $config->{region} || 'ap-southeast-1',
        );
    }
    else {
        $ec2 = Net::Amazon::EC2->new(
            logger => logger(),
            AWSAccessKeyId => $config->{key},
            SecretAccessKey => $config->{secret},
            region => $config->{region} || 'ap-southeast-1',
        );
    }
}

sub ec2 { $ec2 }

my $logger;
sub logger {
    my $name = shift || 'ec2util';
    $logger ||= Log::Log4perl->get_logger($name);
}

sub get_cfg {
    my $name = shift;
    my $cfg = $config->{idp_instances}{$name} or die "$name not found in config";
}

sub _resolve_token {
    my $token = shift;
    my $dt = DateTime->now( time_zone => 'Asia/Tokyo' ); # XXX hack: for us futures to have properly week number
    my $yw = 'W'.join('-', $dt->week);
    my $date = $dt->ymd;
    $token =~ s/\%date/$date/g;
    $token =~ s/\%yw/$yw/g;
    return $token;
}

sub stop_idp_instance {
    my $name = shift;
    my $instance = shift;
    my $cfg = get_cfg($name);

    unless ($instance) {
        my $ami = $cfg->{ami_id} || get_image_by_name($cfg->{ami_name});

        if (my $id = $cfg->{instance_id}) {
            $instance = get_instance_by_id($id);
            unless ($instance) {
                logger()->error("stop: instance '$id' not found");
                return;
            }
        }
        elsif (my $token = $cfg->{client_token}) {
            $token = _resolve_token($token);
            $instance = get_instance_by_token($token);
            unless ($instance) {
                logger()->warn("stop: instance with token '$token' not found");
                return;
            }
        }
        else {
            $instance = get_instance_by_ami($ami);
        }
    }

    my $state = 'terminated';
    my $instance_id = $instance->instance_id;
    if ($cfg->{persistent}) {
        if ($instance->instance_state->name eq 'stopped') {
            logger()->info("instance $instance_id already stopped ($cfg->{ami_name})");
            return;
        }
        logger()->info("stopping instance $instance_id ($cfg->{ami_name})");
        $ec2->stop_instances( InstanceId => $instance_id );
        $state = 'stopped';
    }
    else {
        logger()->info("terminating instance $instance_id ($cfg->{ami_name})");
        $ec2->terminate_instances( InstanceId => $instance_id );
    }

    my $cv = watch_for_instance($instance => $state);
    my ($i_instance, $state_err) = $cv->recv;
    if ( $state_err ) {
        die "===> FAIL to stop instance: ".$i_instance->instance_state->name;
    }
}

sub map_devices {
    my $spec = shift or return;

    my $dev = {
        'BlockDeviceMapping.DeviceName'    => [],
        'BlockDeviceMapping.Ebs.SnapshotId' => [],
    };

    for (@$spec) {
        push @{$dev->{'BlockDeviceMapping.DeviceName'}},    $_->{name};
        push @{$dev->{'BlockDeviceMapping.Ebs.SnapshotId'}}, $_->{snapshot};
    }
    warn Dumper($dev); use Data::Dumper;
    return $dev;
}

sub ensure_idp_instance {
    my $name = shift;
    my $new;
    my $cfg = get_cfg($name);
    my ($instance);

    my $ami = $cfg->{ami_id} || get_image_by_name($cfg->{ami_name});
    my $token;
    my $token_fail;
    if (my $id = $cfg->{instance_id}) {
        $instance = get_instance_by_id($id);
        unless ($instance) {
            logger()->error("instance '$id' not found");
            return;
        }
    }
    elsif ($token = $cfg->{client_token}) {
        $token = _resolve_token($token);
        $instance = get_instance_by_token($token);
        if ($instance && $instance->instance_state->name eq 'terminated') {
            $token_fail = $token;
            undef $instance;
            undef $token;
        }
    }
    else {
        $instance = get_instance_by_ami($ami);
    }

    if (!$instance) {
        my $user_data = $cfg->{user_data};
        if ($cfg->{user_data_file}) {
            open my $fh, '<', $cfg->{user_data_file} or die "$cfg->{user_data_file}: $!";
            local $/; $user_data = <$fh>;
        }
        logger()->info("launching $cfg->{ami_name} -> $ami");
        my $devices = map_devices($cfg->{devices});
        my $opt = {
            ImageId => $ami, MinCount => 1, MaxCount => 1,
            SecurityGroup => $cfg->{security_group},
            InstanceType => $cfg->{type},
            $cfg->{availability_zone} ?
                ('Placement.AvailabilityZone' => $cfg->{availability_zone}) : (),
            $user_data ?
                (UserData => encode_base64($user_data)) : (),
            $token ?
                (ClientToken => $token) : (),
            $cfg->{key_name} ?
                (KeyName => $cfg->{key_name}) : (),
            $devices ? %$devices : (),
            };

        my $r = $ec2->run_instances(%$opt);
        if ($r->isa('Net::Amazon::EC2::Errors')) {
            # XXX: some more retires?
            my $error = $r->errors->[0];
            logger()->error("failed to launch instance: ".$error->code.' '.$error->message.", trying without availability zone");
            delete $opt->{'Placement.AvailabilityZone'};
            $r = $ec2->run_instances(%$opt);
            if ($r->isa('Net::Amazon::EC2::Errors')) {
                logger()->fatal("unable to launch instance: ".$error->code.' '.$error->message);
                return;
            }
        }
        ($instance) = $r->instances_set;

        if ($token_fail) {
            logger()->error("$token_fail already terminated, instance @{[ $instance->instance_id ]} relaunched requiring manual termination");
        }
        $new = 1;
    }
    elsif ($cfg->{persistent} && $instance->instance_state->name eq 'stopped') {
        $ec2->start_instances( InstanceId => $instance->instance_id );
    }

    logger()->info("found instance: @{[$instance->instance_id]} @{[$instance->instance_state->name]}");

    my $cv = watch_for_instance($instance, 'running');

    my ($i_instance, $state_err) = $cv->recv;
    if ($state_err) {
        logger()->error("$name failed to start: $state_err");
        return;
    }
    logger()->info("$name host: ".$i_instance->dns_name);

    if ($cfg->{volumes}) {
        for my $device (sort keys %{$cfg->{volumes}}) {
            my $r = $ec2->attach_volume(
                Device => $device,
                VolumeId => $cfg->{volumes}{$device},
                InstanceId => $instance->instance_id,
            );
            if ($r->isa('Net::Amazon::EC2::Errors')) {
                my $error = $r->errors->[0];
                logger()->error("failed to attach: ".$error->code.' '.$error->message.", trying without availability zone");            }
            else {
                logger()->info("attach volume $cfg->{volumes}{$device} as $device for @{[$instance->instance_id]}: @{[ $r->status ]}");
            }
        }
    }

    ensure_with_ping($i_instance->dns_name);

    if (my $cmd = $cfg->{run_cmd}) {
        my $dns = $i_instance->dns_name;
        $cmd =~ s/\%dns/$dns/g;
        logger()->info("run_cmd: '$cmd'");
        system($cmd) and logger()->error("run_cmd '$cmd' returns: $?");
    }

    return ($i_instance, $new);
}

sub ensure_with_ping {
    my $host = shift;
    my $timeout = 180;

    my $start = time;
    use Net::Ping;
    my $p = Net::Ping->new("tcp");
    $p->port_number(22);

    while (time < $start + $timeout) {
        if ($p->ping($host)) {
            my $latency = time - $start;
            logger()->info("$host reached after $latency seconds");
            return 1;
        }
        sleep 2;
    }
    logger()->error("timeout pinging $host");
}

sub get_instance {
    my $i = shift;
    my $running_instances = $ec2->describe_instances(InstanceId => $i) or die "instance does not exist";

    if (UNIVERSAL::isa($running_instances, 'Net::Amazon::EC2::Errors')) {
        my $error = $running_instances->errors->[0];
        logger()->error("Failed to refresh instance state: $i: ".$error->message);
        return;
    }

    my @instances;
    foreach my $reservation (@$running_instances) {
        foreach my $instance ($reservation->instances_set) {
#            print $instance->instance_id . "\n";
#            print $instance->instance_state->name."\n";
#            print $instance->dns_name."\n";
            push @instances, $instance;
#        warn Dumper($instance) ; use Data::Dumper;
        }
    }
    die join(',',map {$_->instance_id} @instances) unless scalar @instances == 1
;
    return $instances[0];
}

sub get_instance_by_ami {
    my $ami = shift;
    my $running_instances = $ec2->describe_instances;
    my @instances;
    foreach my $reservation (@$running_instances) {
        foreach my $instance ($reservation->instances_set) {
            next if $instance->instance_state->name eq 'terminated';
            push @instances, $instance if $instance->image_id eq $ami;
        }
    }
    die join(',',map {$_->instance_id} @instances) if scalar @instances > 1;
    return $instances[0];
}

sub get_instance_by_token {
    my $token = shift;
    my $running_instances = $ec2->describe_instances( Filter => [ 'client-token' => $token] );
    my @instances;
    foreach my $reservation (@$running_instances) {
        foreach my $instance ($reservation->instances_set) {
            push @instances, $instance;
        }
    }
    die join(',',map {$_->instance_id} @instances) if scalar @instances > 1;
    return $instances[0];
}

sub get_instance_by_id {
    my $id = shift;
    my $running_instances = $ec2->describe_instances( InstanceId => $id );
    my @instances;
    foreach my $reservation (@$running_instances) {
        foreach my $instance ($reservation->instances_set) {
            push @instances, $instance;
        }
    }
    die join(',',map {$_->instance_id} @instances) if scalar @instances > 1;
    return $instances[0];
}

sub get_image_by_name {
    my $name = shift;
    my $images = $ec2->describe_images(Owner => 'self');

    my @images;
    for (@$images) {
        push @images, $_ if $_->name eq $name;
    }
    die join(',',map {$_->instance_id} @images) unless scalar @images == 1;
    return @images ? $images[0]->image_id : undef;
}

sub watch_for_instance {
    my $instance = shift;
    my $status = shift;

    my $try = 0;
    my $cv = AE::cv;
    my $w; $w = AnyEvent->timer(after => 0, interval => 5, cb => sub {
                                    my $new = get_instance($instance->instance_id);
                                    if ($new->isa('Net::Amazon::EC2::Errors')) {
                                        logger()->error("Failed to refresh instance state: @{[ $instance->instance_id ]}");
                                        ++$try;
                                        return;
                                    }
                                    return unless $new;

                                    $instance = $new;
                                    my $instance_state = $instance->instance_state->name;
                                    if ( $instance_state eq $status) {
                                        undef $w;
                                        $cv->send($instance, 0);
                                    }
                                    if (++$try > 12) {
                                        undef $w; $cv->send($instance, $instance_state);
                                    }
                                });
    return $cv;
}

1;
