#!/usr/bin/env bash
#==========================================================================
#
#   Copyright NumFOCUS
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#          https://www.apache.org/licenses/LICENSE-2.0.txt
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
#==========================================================================*/

help_details() {
cat <<helpcontent
Usage: ContentLinkSynchronization.sh [--create] [--root-cid <ITKData root cid>] <ITK source tree path>

This script, given an ExternalData object store, checks all ExternalData
.cid content links in the ITK source are present in the ITKData/Objects/ directory
verifies that hashes correspond to the same file, and creates the corresponding
file entry in the ITK/Data repository.

If content link verification fails, the script notifies the caller and exits.
The error should be resolved manually before re-execution.

Once executed, a datalad commit can be created from the result.

This script should be executed prior to releases. The steps are:

1. Check out the version of ITK whose data will archived.
2. Run this script with the --create flag. This will copy new objects into Objects/CID/.
3. Upload the tree with: w3 put . --no-wrap -n ITKData-pre-verify -H
4. Run this script with the --root-cid flag given the root-cid from the previous step. This will verify and copy data files into their location in the ITK source tree.
5. Commit the result with datalad save -m "ENH: Updates for ITK-v<itk-release-version>"
6. Upload the repository update to web3.storage: w3 put . --no-wrap -n ITKData-v<itk-release-version> -H
7. Pin the resulting root CID for across pinning resources.
helpcontent
}

die() {
  echo "$@" 1>&2; exit 1
}
itk_source_dir=""
root_cid=""
create=false
help=false
while [[ $# -gt 0 ]] ;
do
    opt="$1";
    shift;
    case "$opt" in
        "-h"|"--help")
           help=true;;
        "-c"|"--create")
           create=true;;
        "-r"|"--root-cid")
          opt="$1"
          shift
          root_cid=$opt;;
        *) if test "${itk_source_dir}" = ""; then
             itk_source_dir=$opt;
             if test ! -e $itk_source_dir; then
               die "$itk_source_dir does not exist!"
             fi
           else
             echo >&2 "Invalid option: $opt"
             exit 1
           fi;;
   esac
done

if test "${itk_source_dir}" = "" || $help; then
  help_details
  die
fi

if ! type ipfs > /dev/null; then
  die "Please install the ipfs executable."
fi

top_level_dir=$(git rev-parse --show-toplevel)
cd "$top_level_dir"

mkdir -p Objects/CID
object_store="$top_level_dir/Objects"


verify_cids() {
  cd "$itk_source_dir"
  if test "${root_cid}" = ""; then
    die "--root-cid is required"
  fi
  algo=$1
  algo_upper=$(echo $algo | awk '{print toupper($0)}')
  find . -name "*.$algo" -print0 | while read -d ''  -r content_link; do
    echo "Content link ${content_link} ..."
    if test -z "${content_link}"; then
      die "Empty content link!"
      continue
    fi
    algo_hash=$(cat "${content_link}" | tr -d '[[:space:]]')
    data_path=$(dirname "${content_link}")/$(basename "${content_link}" .${algo})
    object_path="${object_store}/${algo_upper}/${algo_hash}"
    echo "Verifying ${algo_hash} ..."
    if test ! -e "${object_path}"; then
      die "Could not find data object in store for $content_link!"
    fi
    # Verify
    cid_value=$(ipfs dag resolve /ipfs/${root_cid}/Objects/${algo_upper}/${algo_hash} || die "Could not resolve CID!")

    if test $algo = "cid" && test "${cid_value}" != "${algo_hash}"; then
      die "CID value for ${object_store}/${algo_upper}/${algo_hash} does not equal hash in ${content_link}!"
    else
      if test $algo != "cid"; then
        cp "$object_path" "${object_store}/CID/${cid_value}"
        rm -f "${itk_source_dir}/${data_path}.sha512"
      fi
    fi
    output_path="${top_level_dir}/$data_path"
    if ! test -e "$output_path"; then
      mkdir -p $(dirname "$output_path")
      cp "$object_path" "$output_path"
    fi
  done || exit 1
}

create_cids() {
  cd "$itk_source_dir"
  algo=$1
  algo_upper=$(echo $algo | awk '{print toupper($0)}')
  find . -name "*.$algo" -print0 | while read -d ''  -r content_link; do
    echo "Content link ${content_link} ..."
    if test -z "${content_link}"; then
      die "Empty content link!"
      continue
    fi
    algo_hash=$(cat "${content_link}" | tr -d '[[:space:]]')
    data_path=$(dirname "${content_link}")/$(basename "${content_link}" .${algo})
    object_path="${object_store}/${algo_upper}/${algo_hash}"
    echo "Creating ${algo_hash} ${content_link}..."
    if test -e "${object_path}"; then
      if test "$algo" != "cid"; then
        # Create
        if test "${root_cid}" = ""; then
          die "--root-cid is required"
        fi
        cid_value=$(ipfs dag resolve /ipfs/${root_cid}/Objects/${algo_upper}/${algo_hash} || die "Could not resolve CID")
        echo $cid_value > "${itk_source_dir}/${data_path}.cid"
        rm -f "${itk_source_dir}/${data_path}.md5"
      fi
    elif test -e "${ExternalData_OBJECT_STORES}/${algo_upper}/${algo_hash}"; then
      cp "${ExternalData_OBJECT_STORES}/${algo_upper}/${algo_hash}" "${object_store}/${algo_upper}/${algo_hash}"
    elif test "$algo" = "cid"; then
      ipfs get /ipfs/$algo_hash --output="${object_store}/${algo_upper}/${algo_hash}"
    else
      # Expected until everything is migrated to CID's
      echo "Could not find data object in store for $content_link!"
    fi
  done || exit 1
}

if $create; then
  create_cids sha512
  create_cids cid
else
  verify_cids sha512
  verify_cids cid
  echo ""
  echo "Verification completed successfully."
fi

echo ""
echo "Commit new content as necessary."
