# Remove complete logical rules mentioning any retired entry point, including
# continuations and mixed command lists. Preserve unrelated rules byte-for-byte.
function flush() {
    if (record ~ /\/usr\/local\/bin\/(hermes-converger|chief-node-supervisor|chief-update)([[:space:],\\]|$)/ && record !~ /^[[:space:]]*#/) {
        if (record ~ /^[[:space:]]*Cmnd_Alias[[:space:]]/) {
            # Keep alias references valid, but give them only a fixed failing
            # command. They can no longer invoke any Chief entry point.
            gsub(/\/usr\/local\/bin\/(hermes-converger|chief-node-supervisor|chief-update)/, "/usr/bin/false", record)
            printf "%s", record
        } else {
            print "# Step 0: retired Chief privilege rule."
        }
    } else {
        printf "%s", record
    }
    record = ""
}
{ record = record $0 "\n"; if ($0 !~ /\\[[:space:]]*$/) flush() }
END { if (record != "") flush() }
