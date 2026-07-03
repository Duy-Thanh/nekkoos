#! /bin/bash

echo Preparing repository
cp commit-msg .git/hooks
chmod +x ./.git/hooks/commit-msg

if [ ! -f ".git/hooks/commit-msg" ]; then
	echo Failed to prepare repo
	exit 1
else
	echo Repo initialized! Happy coding!
fi
