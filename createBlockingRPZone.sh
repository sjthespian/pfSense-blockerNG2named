#!/bin/sh

#############################################################
# This scripts transforms the pfBlockerNG DNS Blacklist     #
# to a custom named config, that can be included            #
#############################################################
# Documentation can be found here:                          #
# https://github.com/gewuerzgurke84/pfSense-blockerNG2named #
#############################################################

#
# Source Directoy: Directory holding pfBlockerNG feeds
#
sourceFilePattern="/var/db/pfblockerng/dnsbl/*.txt"

#
# Top 1M file
#
top1mFile="/var/db/pfblockerng/top-1m.csv"

#
# WhiteList file from DNSDBL
#
whitelistDNSBL="/var/db/pfblockerng/pfbdnsblsuppression.txt"

#
# Destination Directories: Destination bind/named zone file
#
destZoneFilenameInChroot="/var/etc/named/etc/namedb/fuck.ads.zone"

#
# Destination Virtual IP (please use the same Virtual IP as configured in pfBlockerNG)
#
#destVIP=10.10.10.1
destVIP=`xmllint --xpath "//pfblockerngdnsblsettings/config/pfb_dnsvip/text()" /conf/config.xml`

#
# Unbound mode
#
unboundMode=`xmllint --xpath "//pfblockerngdnsblsettings/config/dnsbl_mode/text()" /conf/config.xml`

#
# Restart named (Y/N)
#
restartNamed="N"
reloadNamed="Y"
# if reload is "Y", space-separated list of zones to reload. Ex. "Internal/blackhole"
reloadZones="Internal/blackhole"

# Check semaphore file, exit if it exists to avoid truncated zone files
semaphore=/tmp/$(basename $0).semaphore
if [ -f $semaphore ]; then
  echo "WARNING: $0 is already running! Exiting"
  exit 1
fi
touch $semaphore

cleanup() {
  /bin/rm -f /tmp/$(basename $0).semaphore
  /bin/rm -f /tmp/.pfBlockerToBind.1 \
             /tmp/.pfBlockerToBind.2 \
             /tmp/.pfBlockerWhitelist
}
trap cleanup EXIT

#
# Get settings for top1M list
alexa_enabled=`xmllint --xpath "//pfblockerngdnsblsettings/config/alexa_enable/text()" /conf/config.xml`
alexa_count=`xmllint --xpath "//pfblockerngdnsblsettings/config/alexa_count/text()" /conf/config.xml`

# DNSBL whitelist
if [ -f $whitelistDNSBL ]; then
  echo "## Processing whitelist"
  # Turn the whitelist into a file of regex matches
  #   lines starting with " are exact matches
  #   lines starting with . are domain matches
  #   add a space after the regex to match the zone file format
  sed 's/^"/^/;s/ .*$/ /;s/\./\\./g' /var/db/pfblockerng/pfbdnsblsuppression.txt | sort | uniq > /tmp/.pfBlockerWhitelist
fi

#
# Clear
#
echo > /tmp/.pfBlockerToBind.1

#
# Collect fqdns and ensure named compatibility
#
echo "# Collecting configured pfBlockerNG DNS Blacklist Files ($sourceFilePattern)"
for blockFile in $sourceFilePattern
do
        echo "## Processing $blockFile"
        # Format of file is "local-data: "<fqdn> IN a <virtual dnsblip>""        

    if [ "$unboundMode" == "dnsbl_python" ]; then
        # Format of file is (I think) ",<zone>,,1,<source>,<group>"
        # We'll make zones bind compatible by removing "_" and "@" and
        # transforming them into a bind entry with destVIP
        awk -F, '(length($2) < 256) && ! ($2~( /[@_]/ || /\.-/ || /-\./)) {printf "%s\tIN\tA\t'$destVIP'\n",$2}' $blockFile >> /tmp/.pfBlockerToBind.1
    else
        # We filter out names that make named complain by violating the grammar
        # and length restrictions of RFC1035. This awk script is an incremental
        # improvement on the original grep filtering, but it really needs to be
        # a proper regex match describing the RFC1035 grammar rather than a
        # filter that looks for specific bad patterns from the blacklist names.
        awk 'BEGIN { FS = ": " } length($2) < 256 && ! ( /[@_]/ || /\"-/ || /\.-/ || /-\./) { gsub("\"","",$2); print $2;}' $blockFile  >> /tmp/.pfBlockerToBind.1
    fi
 
done

#
# Remove entries from whitelist
#
if [ -f /tmp/.pfBlockerWhitelist ]; then
    echo "# Apply whitelist ($whitelistDNSBL)"
    egrep -vf /tmp/.pfBlockerWhitelist /tmp/.pfBlockerToBind.1 > /tmp/.pfBlockerToBind.2
    rm /tmp/.pfBlockerWhitelist
else
    echo "# Whitelist not found ($whitelistDNSBL)"
    mv /tmp/.pfBlockerToBind.1 /tmp/.pfBlockerToBind.2
fi

#
# If enabled, remove entries from top1M
#
# NOTE: this file has crlf line terminations, not just newline
if [ "$alexa_enabled" == "on" ]; then
    echo "# Removing top $alexa_count entries of top1M list"
    sed -n 1,${alexa_count}p $top1mFile | sed 's/^.*,//' | tr '\r' ' IN A' > /tmp/.pfBlockertop1m
    mv /tmp/.pfBlockerToBind.2 /tmp/.pfBlockerToBind.1
    grep -F -vf /tmp/.pfBlockertop1m /tmp/.pfBlockerToBind.1 > /tmp/.pfBlockerToBind.2
    rm /tmp/.pfBlockertop1m
fi

#
# Build resulting RP zone file
#
echo "# Creating zone file ($destZoneFilenameInChroot)"
sn=$(date +%s)
cat > $destZoneFilenameInChroot <<EOF
\$TTL     60
@ IN SOA        localhost. root.localhost. (
    $sn   ; serial number epoch time
         28800   ; refresh 8 hours
          7200   ; retry 2 hours
        864000   ; expire 10 days
         86400 ) ; min ttl 1 day
     NS localhost.

localhost       A       127.0.0.1
EOF

echo "# Build RP Zone File"   
cat /tmp/.pfBlockerToBind.2 >> $destZoneFilenameInChroot     
echo "# Removing invalid DNS names"

# Strip hostname and/or domain name elements starting with '-'
echo "# Cleaning DNS names in Zone File"   
sed -i -e '/^-/d;/\.-/d' /var/etc/named/etc/namedb/fuck.ads.zone

#
# Restart named
# 
if [ "$restartNamed" == "Y" ]; then
    echo "# Restarting named"
    service named.sh restart
fi
if [ "$reloadNamed" == "Y" ]; then
    echo -n "# Reloading named: "
    for z in $reloadZones; do
        echo -n "$z "
        zcmd=`echo $z | awk -F/ '{printf "%s IN %s\n",$2,$1}'`
        rndc reload $zcmd
    done
    echo
fi

echo "# Finished"
