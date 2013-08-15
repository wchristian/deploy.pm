use strictures;

package deploy;

use Moo;
use Capture::Tiny 'capture';
use Object::Remote::Logging qw( :log );
use File::chdir;
use submodule;

sub {
    with "gitrole";
  }
  ->();

sub branches_detailed {
    my ( $self, %args ) = @_;

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

    return @branches;
}

sub run {
    my ( $self, $branch ) = @_;

    die "No branch name given.\n" if !$branch;
    die sprintf "Branch to be checked out cannot be the same as the name of the deployment: %s\n", $self->name
      if $self->name eq $branch;

    $self->is_clean;
    $self->no_unpushed_commits;
    $self->is_on_branch( $self->name );
    $self->checkout_branch( $branch );
    $self->update_submodules;
    $self->carton_update;
    log_info { "* Marking deploy in repo: " . $self->dir };
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

    my @submodules = map { submodule->new( dir => $self->dir . "/$_", name => $self->name ) } $self->submodule_dirs;
    $_->mark_submodule_deploy for @submodules;

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

    local $CWD = $self->dir;

    log_info { "Installing dependencies\n" };
    my ( $out, $err, $res ) = capture { system "carton install" };
    $err =~ s/You have .*? \(.*?\)\n//g;
    $err =~ s/Successfully installed .*?\n//g;
    $err =~ s/. distributions installed\n//g;
    die $err if $res or $err;
    $out =~ s/Installing modules using cpanfile\n\x1B\[32mComplete! Modules were installed into local\n\x1B\[0m//g;
    die $out if $out;

    return;
}

sub fetch_all_remotes {
    my ( $self, $branch ) = @_;
    log_info { "Fetching all remotes\n" };
    my ( undef, $err, $out ) = capture {
        $self->r->run( qw"fetch --all --prune" );
    };
    my $full_err = $err;

=pod
From git.de-nserver.de:web-go_de
   7163b7a..394a3d1  fkoesters_4032_more_corrections -> origin/fkoesters_4032_more_corrections at /loader/0x9bfd018/deploy.pm line 109
=pod
From git.de-nserver.de:web-go_de
 * [new branch]      fkoesters_4032_more_corrections -> origin/fkoesters_4032_more_corrections at /loader/0xa039f50/deploy.pm line 109
=pod
From git.de-nserver.de:web-go_de
 + e7852d5...fa766e4 allow_go_url -> origin/allow_go_url  (forced update)
 + e7852d5...fa766e4 go_live    -> origin/go_live  (forced update) at /loader/0x971da28/deploy.pm line 109
=pod
From git.de-nserver.de:web-phcom_cmsv2
   99856f5..b73c259  live       -> origin/live
From git.de-nserver.de:web-phcom_static_shared
 * [new branch]      fkoesters_3531_favicon -> origin/fkoesters_3531_favicon
 * [new branch]      fkoesters_3958_no-setup-fee -> origin/fkoesters_3958_no-setup-fee
 * [new branch]      go_price   -> origin/go_price
 + f951296...c0ccb19 go_stuff   -> origin/go_stuff  (forced update)
   19b65fa..07a859d  live       -> origin/live
 * [new branch]      new_deploy -> origin/new_deploy at /loader/0x9ddaae0/deploy.pm line 109
=pod
 x [deleted]         (none)     -> origin/proper_price_file
 x [deleted]         (none)     -> origin/ssl_fix at /loader/0x9f1de90/deploy.pm line 109
=cut

    $err =~
s#((|From .*?\n)( [*+ x] ([a-z0-9]+\.+[a-z0-9]+|\[(new branch|deleted)\])\s+([a-z0-9_-]+|\(none\))\s+-> [a-z]+/[a-z0-9_-]+(|\s+\(forced update\))\n?)+)+ at .*? line \d+\n##;

    die "'$err':\n$full_err\n" if $err;
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
    my ( $current_branch ) = $out =~ /# On branch (.*)\n/;

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
    die "$err\n" if $err;
    $self->is_on_branch( $branch );
    return;
}

sub is_on_branch {
    my ( $self, $branch ) = @_;
    die "Not on branch: $branch\n" if $self->current_branch ne $branch;
    log_info { "Is on branch: $branch\n" };
    return;
}

sub is_clean {
    my ( $self ) = @_;

    my $out = $self->r->run( "status" );

    $out =~
      s@# Your branch and '.*?' have diverged,\n# and have \d+ and \d+ different commits each, respectively.\n#\n@@;

    $out =~ s@# Your branch is behind '.*?' by \d+ commits, and can be fast-forwarded.\n#\n@@;

    my ( $current_branch ) = $out =~ /^# On branch (.*)\nnothing to commit,? \(?working directory clean\)?$/;
    die "$out\n" if !$current_branch;
    log_info { "Repo is clean\n" };

    return $current_branch;
}

1;
