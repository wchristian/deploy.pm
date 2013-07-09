use local::lib 'local';

use strictures;

package remote;

use 5.010;
use Moo;
use Ask;
use Getopt::Long::Descriptive;
use JSON 'decode_json';
use IO::All -binary, -utf8;

use lib '.';

$ENV{OBJECT_REMOTE_LOG_FORMAT}     = "[%l %r] [%p]: %s";
$ENV{OBJECT_REMOTE_LOG_FORWARDING} = 1;
$ENV{OBJECT_REMOTE_LOG_LEVEL}      = "verbose";

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

    my $ask = Ask->detect;

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
    my $conn = Object::Remote->connect( $target->{server} );
    my $deployer = deploy->new::on( $conn, name => $opt->{deployment_id}, dir => $target->{dir} );

    $opt->{branch} ||= $self->ask_for_branch( $deployer, $ask );
    die "No branch given.\n" if !$opt->{branch};

    $deployer->run( $opt->{branch} );
    $conn->{send_to_fh}->close;
    sleep 1;

    return;
}

sub ask_for_branch {
    my ( $self, $deployer, $ask ) = @_;
    my @branches = $deployer->branches_detailed( skip => sprintf( '(master|%s)$', $deployer->name ) );
    my @choices = map { [ $_->{id} => "$_->{short_name}: -$_->{commits}[0] +$_->{commits}[1]" ] } @branches;
    my $id = $ask->single_choice( text => "Need a branch", choices => \@choices );
    my ( $branch ) = map { $_->{short_name} } grep { $_->{id} == $id } @branches;
    return $branch;
}
