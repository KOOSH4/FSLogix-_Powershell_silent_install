## Install FSLogix Apps

This script checks the current version of FSLogix based on the short URL redirected filename (eg: FSLogix_Apps_2.9.8440.42104.zip) and installs if FSLogix is not installed, or is older than the currently installed version. Version comparison uses [System.Version] object type cast to ensure any major version numbers are accounted for.

The script will extract just the 64 bit FSLogix Apps installer exe from the downloaded zip

Caveats: If MS changes the short URL, the redirection, or the path/filename within the zip then the script will break.
it is recommended not to autorun this script due to unexpected bugs in FSLogix

Credits: https://www.reddit.com/user/TheScream/