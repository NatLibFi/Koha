#!/bin/sh
# Send e-mail notifications of failed EDItX processing to people defined in procurement-config
# Written by Pasi Korkalo / Koha-Suomi Oy, GNU GPL3 or later applies.

# You will need to add <notifications> part to the end of your procurement-config.xml:

# <notifications>
#   <mailto>someone@somewere.com,someone@else.com</mailto>
# </notifications>

die() { printf "$@\n" ; exit 1 ; }

# Get, set and check variables

export xmllint="$(which xmllint)"
test -n $xmllint || die "No xmllint, apt install libxml2-utils."

mailer="$(which mail)"
test -n $mailer || die "No mail, apt install heirloom-mailx."

test -e $KOHA_CONF || die "No KOHA_CONF."

config_file="$(dirname $KOHA_CONF)/procurement-config.xml"
test -e $config_file || die "No procurement config $config_file."

mailto=$($xmllint --xpath '*/notifications/mailto/text()' $config_file)
export failed_path=$($xmllint --xpath '*/settings/import_failed_path/text()' $config_file)
export log_path=$($xmllint --xpath 'yazgfs/config/logdir/text()' $KOHA_CONF)

test -n $mailto || die "No one to send notifications to in $config_file."
test -n $failed_path || die "No path to failed EDItX messages in $config_file."
test -n $log_path || die "No path to logs in $KOHA_CONF."

# Get failed EDItX notices and send emails

export failed_files="$(ls $failed_path/*.xml 2> /dev/null)"

if test -n "$failed_files"; then

  ( printf "Seuraavien EDItX sanomien käsittelyssä oli ongelmia:\n\n"

    for file in $failed_files; do

      printf "=== Sanoma: $(basename $file) ===\n\n"
      grep "$(basename $file)" $log_path/editx/error.log -B 1 -A 1 | grep -v 'Order processing failed for file' | grep -v '^$'

      unset affected_locations
      for location in $($xmllint --xpath "*/ItemDetail/CopyDetail/DeliverToLocation" $file | sed 's/<\/*DeliverToLocation>/\n/ig' | sort -u); do
        affected_locations="$affected_locations $location"
      done

      test -n "$affected_locations" && printf "\nKoskee:$affected_locations\n"
      printf "\n"

    done

    printf "Virheelliset sanomat on siirretty hakemistoon $failed_path.\n"

  ) | $mailer -s "EDItX sanomien käsittelyssä oli ongelmia" $mailto

fi

# All done, exit gracefully
exit 0
