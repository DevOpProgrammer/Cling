#!/bin/zsh

# List the contents of any archive file supported by 7-Zip

# File paths are passed as arguments to the script
# The first file path is $1, the second is $2, and so on
# The number of arguments is stored in $#
# The arguments are stored in $@ as an array

# Allow script to only appear as an option on files with specific extensions
# extensions: 7z bz2 bzip2 tbz2 tbz gz gzip tgz tar wim swm esd xz txz zip zipx jar xpi odt ods docx xlsx epub apfs apm ar a deb lib arj b64 cab chm chw chi chq msi msp doc xls ppt cpio cramfs dmg ext ext2 ext3 ext4 img fat img hfs hfsx hxs hxi hxr hxq hxw lit ihex iso img lzh lha lzma mbr mslz mub nsis ntfs img mbr rar r00 rpm ppmd qcow qcow2 qcow2c 001 squashfs udf iso img scap uefif vdi vhd vhdx vmdk xar pkg z taz zst tzst

# Make Cling show the output of the script after it finishes executing
# showOutput: true

for file in "$@"; do
    "$CLING_SEVEN_ZIP" l -bso0 "$file"
done
