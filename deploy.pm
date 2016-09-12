package deploy;

use strictures;

use Moo;
use Capture::Tiny 'capture';
use File::chdir;
use Carp 'croak';
use submodule;
use Object::Remote::Logging ':log';

sub {
    with "gitrole";
  }
  ->();

sub BUILD {
    my ( $self ) = @_;
    $CWD = $self->dir;
    return;
}

sub branches_detailed {
    my ( $self, %args ) = @_;

    log_info { "Generating detailed branch info\n" };

    $self->is_on_branch( $self->name );
    $self->is_clean;
    $self->no_unpushed_commits;
    $self->fetch_all_remotes;

    my @branches = grep { /remotes\/origin/ } $self->branches;
    @branches = grep { !/^remotes\/origin\/$args{skip}/ } @branches if $args{skip};
    @branches =
      map {
        {
            name       => $_,
            short_name => ( $_ =~ m#^remotes/origin/(.*)$# ),
            commits    => [ map $self->r->run( qw"rev-list --count", $_ ), "$_..HEAD", "HEAD..$_" ],
        }
      }
      grep { $_ } map { split / /, $_ } @branches;
    $branches[$_]->{id} = $_ for 0 .. $#branches;

    log_info { "Done generating detailed branch info\n" };

    return @branches;
}

sub run {
    my ( $self, $branch, $skip_precheck_and_checkout ) = @_;

    log_info { "Starting deploy\n" };

    die "No branch name given.\n" if !$branch;
    die sprintf "Branch to be checked out cannot be the same as the name of the deployment: %s\n", $self->name
      if $self->name eq $branch;

    if ( !$skip_precheck_and_checkout ) {
        $self->is_on_branch( $self->name );
        $self->is_clean;
        $self->no_unpushed_commits;
        $self->checkout_branch( $branch );
    }

    $self->update_submodules;
    $self->carton_update;
    log_info { sprintf "* Marking deploy in repo: %s\n", $self->dir };
    $self->mark_deploy( $branch );
    $self->mark_deploy_in_submodules;

    log_info { "Deploy complete\n" };

    return;
}

sub checkout_branch {
    my ( $self, $branch ) = @_;
    $self->remove_branch( $branch );
    $self->fetch_all_remotes;
    $self->switch_to_branch( $branch );
    return;
}

sub mark_deploy_in_submodules {
    my ( $self ) = @_;

    my @submodules = map { submodule->new( dir => $_, name => $self->name ) } $self->submodule_dirs;

    for my $submod ( @submodules ) {
        local $CWD = $submod->dir;
        $submod->mark_submodule_deploy;
    }

    return;
}

sub submodule_dirs {
    my ( $self ) = @_;

    my @submodule_dirs = map { ( split " " )[1] } $self->r->run( qw"submodule" );

    return @submodule_dirs;
}

sub no_unpushed_commits {
    my ( $self ) = @_;
    my @unpushed = $self->r->run( qw"log --oneline --all --not --remotes" );
    die sprintf "Unpushed commits (either push commits or remove local branches whose remotes were pruned):\n%s\n",
      join "\n", @unpushed
      if @unpushed;
    log_info { "No unpushed commits\n" };
    return;
}

sub carton_update {
    my ( $self ) = @_;

    log_info { "Installing dependencies\n" };
    my ( $out, $err, $res ) = capture { system "carton install" };
    my ( $orig_out, $orig_err ) = ( $out, $err );
    $err =~ s/You have .*? \(.*?\)\n//g;
    s/Successfully installed .*?\n//g   for $out, $err;
    s/\d+ distributions? installed\n//g for $out, $err;
    die "Error - carton_update:\n$orig_err" if $res or $err;
    $out =~
s/Installing modules using .*?cpanfile\n(?:\x1B\[32m)?Complete! Modules were installed into .*?local\n(?:\x1B\[0m)?//g;
    die "Out - carton_update:\n$orig_out" if $out;

    return;
}

sub fetch_all_remotes {
    my ( $self, $branch ) = @_;
    log_info { "Fetching all remotes\n" };
    my ( undef, $err, $out ) = capture {
        $self->r->run( qw"fetch --all --prune" );
    };
    my $full_err = $err;

    $err =~ s@
        (Warning:\ Permanently\ added\ the\ RSA\ host\ key\ for\ IP\ address\ '\d+\.\d+\.\d+\.\d+'\ to\ the\ list\ of\ known\ hosts.\n)?
        (
            (From\ .*?\n)?
            (
                \ [*+ x]
                \ ([a-z0-9]+\.+[a-z0-9]+|\[(new\ branch|deleted)\])
                \s+([A-Za-z0-9_-]+|\(none\))
                \s+->\ [a-z]+/[A-Za-z0-9_-]+(\s+\(forced\ update\))?\n?
            )+
        )+
        \ at\ .*?\ line\ \d+\.?\n
    @@x;

    die "Error - fetch_all_remotes:\n'$err':\n$full_err\n" if $err;
    return;
}

sub update_submodules {
    my ( $self, $branch ) = @_;
    log_info { "Updating all submodules\n" };
    $self->r->run( qw[submodule update --init] );
    $self->is_clean;
    return;
}

sub current_branch {
    my ( $self ) = @_;

    my $out = $self->r->run( "status" );
    my ( $current_branch ) = $out =~ /(?:# )?On branch (.*)\n/;

    return $current_branch;
}

sub switch_to_branch {
    my ( $self, $branch ) = @_;
    log_info { "Switching to branch: $branch\n" };
    my ( undef, $err, $out ) = capture {
        $self->r->run( qw[checkout], $branch );
    };
    $err =~ s/Switched to a new branch '$branch'( at .*? line .*?)?\n//;
    $err =~ s/Running Git hook 'post-commit', 'post-merge' or 'post-commit' to enforce file permissions...\n//;
    $err =~ s/Done( at .*? line .*?)?\n//;
    die "Error - switch_to_branch:\n$err\n" if $err;
    $self->is_on_branch( $branch );
    return;
}

sub is_on_branch {
    my ( $self, $branch ) = @_;
    croak "is_on_branch: No branch given." if !$branch;
    my $current = $self->current_branch;
    croak "is_on_branch: No current branch." if !$current;
    die "Not on branch: $branch, but on: $current\n" if $current ne $branch;
    log_info { "Is on branch: $branch\n" };
    return;
}

sub is_clean {
    my ( $self ) = @_;

    my $out = $self->r->run( "status" );

    $out =~
      s@# Your branch and '.*?' have diverged,\n# and have \d+ and \d+ different commits each, respectively.\n#\n@@;

    $out =~ s@# Your branch is behind '.*?' by \d+ commits, and can be fast-forwarded.\n#\n@@;

    $out =~ s@Your branch is up-to-date with '.*?'\.\n@@;

    my ( $current_branch ) = $out =~ /^(?:# )?On branch (.*)\nnothing to commit,? \(?working directory clean\)?$/;
    die "Out - is_clean:\n$out\n" if !$current_branch;
    log_info { "Repo is clean\n" };

    return $current_branch;
}

1;
