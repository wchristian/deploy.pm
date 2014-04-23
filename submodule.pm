use strictures;

package submodule;

use Moo;

sub {
    with "gitrole";
  }
  ->();

sub log_info (&) { print STDERR shift->() }

sub mark_submodule_deploy {
    my ( $self ) = @_;

    log_info { sprintf "* Marking deploy in submodule: %s\n", $self->dir };

    my $branch = "submodule_deploy_marker";

    $self->remove_branch( $branch );
    $self->create_branch( $branch );

    $self->mark_deploy( $branch );

    return;
}

1;
