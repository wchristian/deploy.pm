use strictures;

package gitrole;

use Moo::Role;
use Git::Repository;
use Object::Remote::Logging qw( :log );
use Capture::Tiny 'capture';

sub {
    has $_ => ( is => 'ro', required => 1 ) for qw( dir name );
    has r => ( is => 'lazy', builder => 1 );
  }
  ->();

sub _build_r { Git::Repository->new( work_tree => shift->dir, { fatal => '!0' } ) }

sub remove_branch {
    my ( $self, $branch, $type, @args ) = @_;
    $type ||= "local";
    @args = qw(-D) if !@args;
    log_info { "Removing $type branch: $branch\n" };
    my %branches = map { $_ => 1 } $self->branches;
    return if !$branches{$branch};
    $self->r->run( 'branch', @args, $branch );
    return;
}

sub branches {
    my ( $self ) = @_;

    my @branches = split /[\n\s]+/, $self->r->run( qw"branch --all" );
    @branches = grep { !/(^\*|\/HEAD)$/ } @branches;
    @branches = sort @branches;

    return @branches;
}

sub remove_remote_branch {
    my ( $self, $remote, $branch ) = @_;
    $self->remove_branch( "$remote/$branch", "remote", qw[-d -r] );
    return;
}

sub create_branch {
    my ( $self, $branch ) = @_;
    log_info { "Creating branch: $branch\n" };
    my ( undef, $err, $out ) = capture {
        $self->r->run( qw[checkout -b], $branch );
    };
    $err =~ s/Switched to a new branch '$branch'( at .*? line .*?)?\n//;
    $err =~ s/Running Git hook 'post-commit', 'post-merge' or 'post-commit' to enforce file permissions...\n//;
    $err =~ s/Done( at .*? line .*?)?\n//;
    die "$err\n" if $err;
    return;
}

sub push_branch {
    my ( $self, $branch ) = @_;
    log_info { "Pushing branch: $branch\n" };
    my ( undef, $err, $out ) = capture {
        $self->r->run( qw[push -f origin], $branch );
    };
    my $full_err = $err;

=pod
To git@git.de-nserver.de:web-go_de.git
   1a92bb3..fa766e4  go_live -> go_live at /loader/0x92cbfb0/deploy.pm line 146
=pod
To git@git.de-nserver.de:web-go_de.git
 + fa766e4...1a92bb3 go_live -> go_live (forced update) at /loader/0xa450078/deploy.pm line 146
=pod
To git@git.de-nserver.de:web-phcom_edit_tool.git
 * [new branch]      go_test -> go_test at /loader/0x9c1db18/gitrole.pm line 62
=cut

    $err =~
s#(To .*?\n( [+* ] ([a-z0-9]+\.+[a-z0-9]+|\[new branch\])\s+[a-z0-9_-]+\s+-> [a-z0-9_-]+(|\s+\(forced update\))\n?)|Everything up-to-date) at .*? line \d+\n##;

    die "'$err':\n$full_err\n" if $err;
    return;
}

sub mark_deploy {
    my ( $self, $branch ) = @_;

    $self->remove_branch( $self->name );
    $self->remove_remote_branch( "origin", $self->name );
    $self->create_branch( $self->name );
    $self->remove_branch( $branch );
    $self->push_branch( $self->name );
    
    return;
}

1;