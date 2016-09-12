package remote;

use local::lib 'local';

use strictures;

use 5.010;
use Moo;
use Ask::STDIO;
use Getopt::Long::Descriptive;
use JSON 'decode_json';
use IO::All -binary, -utf8;
use Try::Tiny;
use curry;

BEGIN {    # must be set up before OR::Logging is loaded to be global
    $ENV{OBJECT_REMOTE_LOG_FORMAT}     = "[%t] [%l %r] [%p]: %s";
    $ENV{OBJECT_REMOTE_LOG_FORWARDING} = 1;
    $ENV{OBJECT_REMOTE_LOG_LEVEL}      = "verbose";
}
use Object::Remote::Logging ':log';

use lib '.';

__PACKAGE__->new->run( @ARGV ) if !caller;
exit;

sub run {
    my ( $self, @args ) = @_;

    say "";

    @ARGV = @args;
    my ( $opt, $usage ) = describe_options(
        'remote.pl %o',
        [ 'deployment_id|d=s', "the deployment id to connect to" ],
        [ 'branch|b=s',        "the branch to deploy" ],
        [], [ 'help', "print usage message and exit" ],
    );
    print( $usage->text ), exit if $opt->help;

    my $ask = Ask::STDIO->new;

    my @targets = @{ decode_json io( "deploy.json" )->all };

    $opt->{deployment_id} ||= do {
        my @choices = map { [ $_ => $targets[$_]{name} ] } 0 .. $#targets;
        my $id = $ask->single_choice( text => "Need a deployment id", choices => \@choices );
        $targets[$id]{name};
    };

    my ( $target ) = grep { $_->{name} eq $opt->{deployment_id} } @targets
      or die "target $opt->{deployment_id} unknown";

    require Object::Remote;
    require deploy;
    log_info { "Connecting to server\n" };
    my $conn = Object::Remote->connect( $target->{server}, timeout => 60 );
    log_info { "Creating remote object\n" };
    my $deployer = deploy->new::on( $conn, name => $opt->{deployment_id}, dir => $target->{dir} );

    log_info { "Getting possible branches\n" };
    $opt->{branch} ||= $self->ask_for_branch( $deployer, $ask );
    die "No branch given.\n" if !$opt->{branch};

    my @deploy_args = ( $opt->{branch} );
    while ( @deploy_args ) {
        try {
            $deployer->run( @deploy_args );
            @deploy_args = ();
        }
        catch {
            my $e = $_;
            die $e unless my $action = $self->get_action_for_error( $e );
            @deploy_args = $action->( $e, $opt->{branch}, $ask );
        }
    }

    $conn->{send_to_fh}->close;
    sleep 1;

    return;
}

sub get_action_for_error {
    my ( $self, $error ) = @_;
    return $self->curry::ask_for_retry_from_submodule_update
      if $error =~ /fatal: reference is not a tree: \w+\s+Unable to checkout '\w+' in submodule path '\w+'/;
    return;
}

sub ask_for_retry_from_submodule_update {
    my ( $self, $error, $branch, $ask ) = @_;
    return
      if !$ask->question( text => "\nTried to update submodule to commit that wasn't pushed:\n\n$error\n"
          . "You have a chance to push the submodule now.\nRetry submodule update? [y/N]" );
    return ( $branch, "skip_precheck_and_checkout" );
}

sub ask_for_branch {
    my ( $self, $deployer, $ask ) = @_;
    my @branches = $deployer->branches_detailed( skip => sprintf( '(master|%s)$', $deployer->name ) );
    my @choices = map { [ $_->{id} => "$_->{short_name}: -$_->{commits}[0] +$_->{commits}[1]" ] } @branches;
    my $id = $ask->single_choice( text => "Need a branch", choices => \@choices );
    my ( $branch ) = map { $_->{short_name} } grep { $_->{id} == $id } @branches;
    return $branch;
}
