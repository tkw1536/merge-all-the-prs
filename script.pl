#!/usr/bin/env perl

use strict;

use REST::Client;
use MIME::Base64 qw(encode_base64);
use LWP::UserAgent;
use Getopt::Long qw(GetOptionsFromArray);
use JSON qw(from_json);

# 'main' is the main entry point to this script.
# Given arguments provided to this script, it runs the code and returns an exit code.
sub main {

    # setup defaults for arguments
    my $help = 0;
    my $auth = undef;
    my $remote = 'origin';
    my $base = 'master';
    my $label = undef;
    my $collabs = 0;
    my $continue = 0;

    # ./script.pl [--help] [--auth AUTH] [--remote REMOTE] [--base BASE] [--label LABEL] [--continue] FOLDER BRANCH
    GetOptionsFromArray(
        \@_,
        "help"          => \$help,
        "auth=s"        => \$auth,
        "remote=s"      => \$remote,
        "base=s"        => \$base,
        "label=s"       => \$label,
        "collabs"       => \$collabs,
        "continue"      => \$continue,
    ) or return print_usage_and_help(1);

    # print help if it was requested or the wrong number of arguments was passed
    return print_usage_and_help(0) if $help;
    return print_usage_and_help(1) if (scalar(@_) != 2);

    # parse non-named arguments
    my ($folder, $branchname) = @_;

    # change directory to the given folder
    my ($ok, $error) = set_cwd($folder);
    if (defined($error) || !$ok) {
        print STDERR "Unable to change directory. \n";
        print STDERR $error . "\n" if defined($error);
        return 1;
    }
    print "Using local directory:   '$folder'\n";

    # find the github repo associated with it
    my ($repo);
    ($repo, $error) = get_github_repo($remote);
    if (defined($error)) {
        print STDERR "Unable to find github repository. \n";
        print STDERR $error . "\n";
        return 1;
    }
    print "Found GitHub repository: '$repo'\n";

    # get all the prs, TODO: Support for token
    my ($prs);
    ($prs, $error) = fetch_repository_prs($auth, $repo, $base, $label, $collabs);
    if (defined($error)) {
        print STDERR "Unable to query for open Pull Requests. \n";
        print STDERR $error . "\n";
        return 1;
    }

    print "Found " . scalar(@$prs) . ' open PR(s)' . (defined($label) ? " with label '$label'" . ($collabs ? ' from contributors with push access' : ''): '') . ".\n";

    # Create a new branch
    ($ok, $error) = force_new_branch($base, $remote, $branchname);
    if (defined($error) || !$ok) {
        print STDERR "Unable to create a new branch. \n";
        print STDERR $error . "\n" if defined($error);
        return 1;
    }
    print "Created and switched to new branch '$branchname'.\n";
    

    # Merge each pr one by one into this branch
    my ($merged, $failed);
    ($merged, $failed, $error) = merge_prs($remote, $prs, $continue);
    if (defined($error)) {
        print STDERR "Unable to merge pull requests. \n";
        print STDERR $error . "\n" if defined($error);
        return 1;
    }
    print "\n\n";
    print "Merged " . scalar(@$merged) . " PR(s) onto the '$branchname' branch. \n";
    print "Merged pull requests: " . join(', ', @$merged) . "\n" if (scalar(@$merged) > 0);
    print "Failed pull requests: " . join(', ', @$failed) . "\n" if ($continue && scalar(@$failed) > 0);

    return 0;
}

sub print_usage_and_help {
    my ($return_code) = @_;
    print STDERR <<'END_MESSAGE';
./script.pl [--help] [--token TOKEN] [--remote REMOTE] [--base BASE] [--label LABEL] [--continue] FOLDER BRANCH

Merges open pull requests onto a new local branch. 

Arguments:

    FOLDER
        Local folder the git repository can be found in.
    BRANCH
        Name of new branch to create locally. Any existing branch may be overwritten.
    --help
        Print this message and exit.
    --auth AUTH
        Optional. GitHub API Credentials in the form "user:password" to use for requests to GitHub. 
        "password" may be a personal access token. Defaults to using no authorization.
    --remote REMOTE
        Optional. git remote to use for communication with GitHub. Defaults to 'origin'.
    --base BASE
        Base branch to start process from. Defaults to 'master'. 
    --label LABEL
        Optional label to filter pull requests by.
    --collabs
        When provided and filtering is enabled (via --label), allow only PRs from collaborators with
        push access to the repository. 
    --continue
        By default, if a pull request fails to merge the process is aborted and an error is thrown.
        This flag overrides the behaviour and simply skips the problematic pull requests.
END_MESSAGE
    return $return_code;
}

# 'set_cwd' sets the working directory to the given folder and returns a pair ($ok, $error).
sub set_cwd {
    my ($folder) = @_;

    # complain if the folder wasn't provided
    return undef, 'Missing folder argument' unless defined($folder);
    
    # check if the folder exists
    return undef, "'$folder' is not a directory" unless (-d $folder);

    return 0, undef unless chdir $folder;
    return 1, undef;
}

# 'get_github_repo' gets the github repository belonging to the remote with the given name in the current folder.
# Returns a pair ($remote, $error) where $remote is either the returned remote or undef if something went wrong and $error is an optional error message. 
sub get_github_repo {
    my ($name) = @_;
    return undef, "No name provided" unless defined($name);
    
    # get the 'origin' remote url
    my $remote = `git config --get remote.$name.url 2> /dev/null`;
    return undef, "Cannot determine origin url -- is this a valid git repository and is git installed?" unless defined($remote) && $remote;
    chomp($remote);

    # match the github repo
    my ($github) = $remote =~ m/github\.com[\/:]([a-zA-Z0-9-_]+\/[a-zA-Z0-9-_]+)(\.git)?$/;
    return undef, "Cannot find GitHub repository that belongs to '$remote'." unless defined($github);

    # and return
    return $github, undef;
}

# 'fetch_repository_prs' fetches the open PRs that are associated with a repository that have a certain label.
# Returns a pair ($prs, $error)
sub fetch_repository_prs {
    my ($auth, $repository, $base, $label, $require_collab, $maxpages) = @_;

    return undef, "No repository provided" unless defined($repository);
    return undef, "No base provided" unless defined($base);
    
    # build a new client and prepare the url
    my $ua = LWP::UserAgent->new(); # TODO: Do we want a custom user agent?
    my $client = REST::Client->new(useragent => $ua);
    my $url = "https://api.github.com/repos/$repository/pulls?state=open&base=$base";

    # fetch the collaborators
    my ($collabs, $derror, @collabs, %collabs);
    if ($require_collab) {
        ($collabs, $derror) = fetch_repo_collabs($client, $auth, $repository, $maxpages);
        return undef, $derror if defined($derror);
        foreach my $c (@$collabs){
            $collabs{$c} = 1;
        }
    }

    # fetch the data
    my ($data, $error) = github_fetch_json_withnext($client, $url, $auth, defined($maxpages) ? $maxpages : 100);
    return undef, $error if defined($error);
    
    # filter prs by label
    my (@prs) = @$data;
    if(defined($label)) {
        my @indexes = grep {


            # get all the labels of this pr
            my @labels = @ { $prs[$_]{'labels'} };

            # put their names into a hash
            my %hash = map { $labels[$_]{'name'} => 1 } 0..$#labels;

            # if we require the right submitter
            my $collab = 1;
            if ($require_collab) {
                my $user = $prs[$_]{'user'}{'login'};
                $collab = defined($collabs{$user});
            }

            # check if we have the appropriate label
            # and the collaborator if needed
            $collab && defined($hash{$label});
        } 0..$#prs;
        @prs = map { $prs[$_] } @indexes;
    }

    # map onto their PR numnbers
    @prs = map { $prs[$_]{'number'}} 0..$#prs;

    # and return
    return [@prs], undef;
}

# 'fetch_repo_collabs' fetches a list of collaborators with write access to a repository. 
# Returns a pair ($@users, $error)
sub fetch_repo_collabs {
    my ($client, $auth, $repository, $maxpages) = @_;

    my $url = "https://api.github.com/repos/$repository/collaborators";

    my @users = ();

    my ($data, $error) = github_fetch_json_withnext($client, $url, $auth, defined($maxpages) ? $maxpages : 100);
    return undef, $error if defined($error);

    # filter the ones that are allowed to push
    # and only include their username
    foreach my $u (@$data) {
        my %uh = %$u;
        if ($uh{'permissions'}{'push'}) {
            push(@users, $uh{'login'});
        }
    }
    
    return [@users], undef;

}

# 'github_fetch_json_withnext' recursively fetches all results of a GitHub API GET request to the given url.
# Returns a pair ($@results, $error)
sub github_fetch_json_withnext {
    my ($client, $url, $auth, $maxpages) = @_;

    # if we are supposed to fetch 0 pages, return
    return [], undef if $maxpages <= 0;

    # prepate the request
    print STDERR "=> Fetching '$url' ...\n";
    my %headers = {Accept => 'application/vnd.github.v3+json'};
    $headers{'Authorization'} = 'Basic ' . encode_base64($auth) if defined($auth);

    # make it and check for return code
    my ($result) = $client->GET($url, \%headers);
    my $code = $result->responseCode();
    return undef, "Request to '$url' returned HTTP $code, expected HTTP 200." unless ($code == 200);

    # grab the json array of data
    my $content = $result->responseContent();
    my $data = from_json($content);
    return undef, "Request to '$url' returned '$content', which is not a valid array. " unless ref $data eq 'ARRAY';

    # check and extract the header for the next link
    my $linkHeader = $result->responseHeader('Link');
    return $data, undef unless defined($linkHeader);
    my ($nextUrl) = $linkHeader =~ m/<([^>]+)>; rel="next"/;
    return $data, undef unless defined($nextUrl);

    # grab the next page, if there is an error return the error
    my ($nextdata, $nexterror) = github_fetch_json_withnext($client, $nextUrl, $auth, $maxpages - 1);
    return undef, $nexterror if defined($nexterror);

    # else concatinate the data with the current one
    return [@$data, @$nextdata], undef;
}

# 'force_new_branch' makes a new branch '$name' from remote '$remote' that points to $base
sub force_new_branch {
    my ($base, $remote, $name) = @_;

    return undef, "No base provided" unless defined($base);
    return undef, "No remote provided" unless defined($remote);
    return undef, "No name provided" unless defined($name);

    # Switch to the base branch
    my $switchCommand = "git checkout $base";
    print STDERR '=> ' . "$switchCommand\n";
    return undef, "Unable to switch to base branch" unless
        system($switchCommand) == 0;

    # Delete the branch unless it exists
    if(system("git rev-parse --verify $name > /dev/null 2> /dev/null") == 0) {
        my $delCommand = "git branch -D $name";
        print STDERR '=> ' . "$delCommand\n";
        return undef, "Unable to delete branch '$name'"
            unless system($delCommand) == 0;
    }
    
    # Fetch the remote
    my $fetchCommand = "git fetch $remote";
    print STDERR '=> ' . "$fetchCommand\n";
    return undef, "Unable to fetch remote '$remote'"
        unless system($fetchCommand) == 0;
    
    # Switch and create the new branch
    my $createCommand = "git branch --no-track $name $remote/$base";
    print STDERR '=> ' . "$createCommand\n";
    return undef, "Unable to create branch $name"
        unless system($createCommand) == 0;

    $switchCommand = "git checkout $name";
    print STDERR '=> ' . "$switchCommand\n";
    return undef, "Unable to switch to new branch" unless
        system($switchCommand) == 0;

    return 1, undef;
}

# 'merge_prs' merges all prs with the given numbers onto the current branch. 
# When continue is true, skips over pull requests that could not be merged. 
sub merge_prs {
    my ($remote, $numbers, $continue) = @_;

    my @merged = ();
    my @failed = ();

    # iterate over all pull requests
    my ($number);
    foreach $number (sort @$numbers) {
        my $fetchCommand = "git fetch $remote pull/$number/head";
        print STDERR '=> ' . "$fetchCommand\n";
        return [@merged], [@failed], "Failed to fetch commits for PR $number"
            unless system($fetchCommand) == 0;
        
        my $mergeCommand = "git merge --no-edit FETCH_HEAD -X ours";
        print STDERR '=> ' . "$mergeCommand\n";
        unless (system($mergeCommand) == 0) {
            push(@failed, $number);

            # If the merge failed, something terrible happened. 
            # We abort the merge to get the checkout to some reasonable state. 
            system("git merge --abort");
            return [@merged], [@failed], "Failed to merge PR $number (too many conflicts?)" unless $continue;

            print STDERR "Failed to merge PR $number, continuing with other pull requests. \n";
            next;
        }

        push(@merged, $number);
    }

    # done
    return [@merged], [@failed], undef;
}


#### Main Code
exit main(@ARGV);