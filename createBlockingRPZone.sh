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
destZoneFilenameInChroot="/cf/named/etc/namedb/fuck.ads.zone"

#
# Destination Virtual IP (please use the same Virtual IP as configured in pfBlockerNG)
#
#destVIP=10.10.10.1
destVIP=`xmllint --xpath "//pfblockerngdnsblsettings/config/pfb_dnsvip/text()" /conf/config.xml`

#
# Restart named (Y/N)
#
restartNamed="N"
reloadNamed="Y"
# if reload is "Y", space-separated list of zones to reload. Ex. "Internal/blackhole"
reloadZones="Internal/blackhole"

#
# Get settings for top1M list
alexa_enabled=`xmllint --xpath "//pfblockerngdnsblsettings/config/alexa_enable/text()" /conf/config.xml`
alexa_count=`xmllint --xpath "//pfblockerngdnsblsettings/config/alexa_count/text()" /conf/config.xml`

# DNSBL whitelist
if [ -f $whitelistDNSBL ]; then
  dnsblwhregex=`sed 's/^"//;s/ .*$//;s/\./\\./g' /var/db/pfblockerng/pfbdnsblsuppression.txt | tr '\n' '|' | sed 's/|$//'`
fi

#
# Write zone file
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

#
# Clear
#
echo > /tmp/.pfBlockerToBind.1

#
# Collect zones and ensure bind compatibility
#
echo "# Collecting configured pfBlockerNG DNS Blacklist Files ($sourceFilePattern)"
for blockFile in $sourceFilePattern
do
        echo "## Processing $blockFile"
        # Format of file is "local-data: "<zone> IN a <virtual dnsblip>""        
        # We'll make zones bind compatible by removing "_" and "@" and transforming them
        cat $blockFile | cut -d\" -f2 | grep -v _ | grep -v "@" |grep $destVIP >> /tmp/.pfBlockerToBind.1        
done

#
# Remove entries from whitelist
#
if [ -n "$dnsblwhregex" ]; then
    echo "# Apply whitelist ($whitelistDNSBL)"
    egrep -v $dnsblwhregex /tmp/.pfBlockerToBind.1 > /tmp/.pfBlockerToBind.2
else
    echo "# Whitelist not found ($whitelistDNSBL)"
    cp /tmp/.pfBlockerToBind.1 /tmp/.pfBlockerToBind.2
fi

#
# If enabled, remove entries from top1M
#
# NOTE: this file has crlf line terminations, not just newline
if [ "$alexa_enabled" == "on" ]; then
    echo "# Removing top $alexa_count entries of top1M list"
    sed -n 1,${alexa_count}p $top1mFile | sed 's/^.*,//' | tr '\r' ' IN A' > /tmp/.pfBlockertop1m
    cp /tmp/.pfBlockerToBind.2 /tmp/.pfBlockerToBind.1
    grep -F -vf /tmp/.pfBlockertop1m /tmp/.pfBlockerToBind.1 > /tmp/.pfBlockerToBind.2
    rm /tmp/.pfBlockertop1m
fi

#
# Build resulting RP zone file
#
echo "# Build RP Zone File"   
cat /tmp/.pfBlockerToBind.2 >> $destZoneFilenameInChroot     

#
# Cleanup
#        
rm /tmp/.pfBlockerToBind.1
rm /tmp/.pfBlockerToBind.2

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
