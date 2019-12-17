# merge-all-the-prs

```
./script.pl [--help] [--token TOKEN] [--remote REMOTE] [--base BASE] [--label LABEL] FOLDER BRANCH

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
```

Note that this script is not secured against malicious arguments. 