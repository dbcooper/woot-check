
I tested this code on Ubuntu 14 x86_64 running Perlbrew w/ Perl 5.22.3 and Windows 10 x86_64 w/ Strawberry Perl 5.24.0.

I haven't tested a full install from scratch so the cpanfile may be lacking.

I use cpanm (`App::cpanminus`), so ideally you only need to do the following:

    cpanm --installdeps .
    cp woot.conf-default woot.conf

Modify the `woot.conf` to add your Woot.com API key and adjust keywords as desired.  Script is hardcoded to only look at Woot! deals on computers but I think the links could be modified slightly to include a broader product search

See https://account.woot.com/applications for your API key (you'll need an account)

To execute the script (Windows):

    perl woot_check.pl

