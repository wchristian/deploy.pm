use strictures;

package submodule;

use Moo;
use Object::Remote::Logging qw( :log );

sub {
    with "gitrole";
  }
  ->();

sub mark_submodule_deploy {
    my ( $self ) = @_;

    log_info { "* Marking deploy in submodule: " . $self->dir };

    my $branch = "submodule_deploy_marker";

    $self->remove_branch( $branch );
    $self->create_branch( $branch );

    $self->mark_deploy( $branch );

    return;
}

1;
