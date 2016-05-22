use strictures;

package gitrole;

use Moo::Role;
use Git::Repository;
use Capture::Tiny 'capture';

sub {
    has $_ => ( is => 'ro', required => 1 ) for qw( dir name );
    has r => ( is => 'lazy', builder => 1 );
  }
  ->();

sub _build_r {
    my $r = Git::Repository->new( { fatal => '!0' } );
    $r->{work_tree} = undef;
    return $r;
}

sub log_info (&) { print STDERR shift->() }

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
    die "Error - create_branch:\n$err\n" if $err;
    return;
}

sub push_branch {
    my ( $self, $branch ) = @_;
    log_info { "Pushing branch: $branch\n" };
    my ( undef, $err, $out ) = capture {
        $self->r->run( qw[push -f origin], $branch );
    };
    my $full_err = $err;

    $err =~
s#(To .*?\n( [+* ] ([a-z0-9]+\.+[a-z0-9]+|\[new branch\])\s+[a-z0-9_-]+\s+-> [a-z0-9_-]+(\s+\(forced update\))?\n?)|Everything up-to-date) at .*? line \d+\.?\n##;

    die "Error - push_branch:\n'$err':\n$full_err\n" if $err;
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
