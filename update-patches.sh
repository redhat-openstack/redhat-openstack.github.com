#!/bin/bash

# This script formats the patches from a git branch, adds them
# to the current branch and updates the spec file

# To use it, do e.g.
#
#   $> project=nova
#   $> git checkout master
#   $> git remote add -f redhat-openstack git@github.com:redhat-openstack/$project.git
#   $> git branch master-patches redhat-openstack/master-patches
#   $> ./update-patches.sh
#
# Now you're left with a commit which updates the patches
#
# When you've pushed and built the package, don't forget to also
# push the patches with e.g.
#
#   $> git push --tags redhat-openstack +master-patches
#

set -e # exit on failure

git status -uno --porcelain | grep . && {
    echo "The repo is not clean. Aborting" >&2
    exit 1
}

filterdiff /dev/null || {
    echo "Please install patchutils" >&2
    exit 1
}

if fedpkg --help >/dev/null 2>&1; then
  fedpkg=fedpkg
elif rhpkg --help >/dev/null 2>&1; then
  fedpkg=rhpkg
else
  echo "Neither fedpkg or rhpkg found" >&2
  exit 1
fi

spec=$($fedpkg gimmespec)
branch=$(git branch | awk '/^\* / {print $2}')
patches_branch="${branch}-patches"
patches_base=$(awk -F '=' '/^# patches_base/ { print $2 }' "${spec}")
patches_skip=${patches_base##*+} # extract skip count
[ "$patches_skip" = "$patches_base" ] && patches_skip=0
patches_base=${patches_base%+*} # strip skip count

orig_patches=$(awk '/^#?Patch[0-9][0-9]*:/ { print $2 }' "${spec}")

#
# Create a commit which removes all the patches
#
if [ "${orig_patches}" ]; then
    git rm ${orig_patches}
fi
git commit --allow-empty -m "Updated patches from ${patches_branch}" ${orig_patches}

#
# Check out the ${branch}-patches branch and format the patches
#
git checkout "${patches_branch}"

# avoid putting changeable git version in patches if possible
git format-patch --no-signature 2>/dev/null && nosig='--no-signature'

start_commit=$(git log --oneline --ancestry-path ${patches_base}.. |
               head -n-${patches_skip} | tail -n1 | cut -d ' ' -f1)

if test "$start_commit"; then
    new_patches=$(git format-patch --no-renames $nosig -N "${start_commit}~")

    #
    # Filter non dist files from the patches as otherwise
    # `patch` will prompt/fail for the non existent files
    #
    for patch in $new_patches; do
        filterdiff -x '*/.*' $patch > $patch.$$
        mv $patch.$$ $patch
    done
else
    echo 'Warning: no patches found' >&2
fi

#
# Switch back to the original branch and add the patches
#
git checkout "${branch}"

#
# Remove the Patch/%patch lines from the spec file
#
sed -i '/^#\?\(Patch\|%patch\)[0-9][0-9]*/d' "${spec}"

if test "${new_patches}"; then
    git add ${new_patches}

    #
    # Add a new set of Patch/%patch lines
    #
    patches_list=$(mktemp)
    patches_apply=$(mktemp)

    trap "rm '${patches_list}' '${patches_apply}'" EXIT

    i=1;
    for p in ${new_patches}; do
        printf "Patch%.4d: %s\n" "${i}" "${p}" >> "${patches_list}"
        printf "%%patch%.4d -p1\n" "${i}" >> "${patches_apply}"
        i=$((i+1))
    done

    sed -i -e "/^# patches_base/ { N; r ${patches_list}" -e "}" "${spec}"
    sed -i -e "/^%setup -q/ { N; r ${patches_apply}" -e "}" "${spec}"
fi

#
# Update the original commit to include the new set of patches
#
git commit --amend -a -m "Updated patches from ${patches_branch}"
