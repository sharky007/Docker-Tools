#!/bin/bash

mode="0"				#
path=""					# absolute path of docker compose file
dir=""					# absolute path of folder containing the docker compose file
name=""					# name of the docker compose file
logpath=""				# absolute path of the logfile
autoupdate="1"				
containerrestart="0"			# load new images and resart corresponding containers if =1
nobackup="0"				# do not create backup if =1
nolog="0"				# do not create log if =1
nonstable="0"                           # include non stabel versions (rc, beta...) if=1
date=$(date +"%Y.%m.%d_%H:%M:%S")	# current date during start

# compare two versions, return values:
#  0 : versions are idetical
#  1 : $1 > $2
#  2 : $1 < $2
#  3 : $1 and $2 have different details 
#  4 : $1 and $2 are not coperable
#  5 : $2 is not a stable version
# -1 : something went wrong
vercomp () {
   # Version is the same
   if [[ $1 == $2 ]]
   then
      return 0
   fi

   # Version contains specific strings marking them as not stable    
   if [[ "$nonstable" != "1" ]]; then 
      if [[ "$2" =~ "beta" || "$2" =~ "rc" || "$2" =~ "snapshot" || "$2" =~ "nightly" ]]; then
         return 5
      fi
   fi
  
   # iterate over every part of the tag seperated by .
   for i in {1..6}; do
      p1=$(echo $1 | cut -d "." -f$i -s)
      p2=$(echo $2 | cut -d "." -f$i -s)

      # only for the first round, check whether the parameter are "" to avoid errors 
      if [[ "$i" == "1" ]]; then
         if [[ "$p1" == "" ]]; then
            p1=$1
         fi
         if [[ "$p2" == "" ]]; then
            p2=$2
         fi
      fi

      # check whether one of the parameters is empty, if yes they are of different detail 
      if [[ "$p1" == "" || "$p2" == "" ]]; then
         return 3
      fi

      # check for TODO 
      if [[ $(echo $p1 | grep -o "[a-zA-Z]" | wc -l) != $(echo $p2 | grep -o "[a-zA-Z]" | wc -l) ]]; then
         return 4
      fi

      # compare the curent version parts
      if [[ $(($p1)) -gt $(($p2)) ]]; then
         return 1
      fi
      if [[ "$p1" -lt "$p2" ]]; then
         return 2
      fi
      
   done
   
   return -1
}

#$container $count $newtags
update () { 
   # check if no update was found
   if [[ "$2" == "0" ]]; then
      output "   No Update available"
      return
   fi
   # check if only one update was found
   if [[ "$2" == "1" ]]; then
      # check if found update is a major update or not
      if [[ "$(echo $1 | cut -d':' -f2 | cut -d'.' -f1)" != "$(echo $3 | cut -d'.' -f1)" ]]; then
         output "   WARNING: Major update available ($3)"
         return
      else
         output "   Update $(echo $1 | cut -d":" -f1) from $(echo $1 | cut -d":" -f2) to $3"
         sed -i "s|$1|$(echo $1 | cut -d":" -f1):$3|g" "$path"
         return
      fi
   fi
   # check if there were more than one updates found
   if [[ "$2" > "1" ]]; then
      for (( i=1; i<=$2; i++ )); do
         tmp=$(echo $3 | cut -d"|" -f"$i")
         if [[ "$(echo $1 | cut -d':' -f2 | cut -d'.' -f1)" != "$(echo $tmp | cut -d'.' -f1)" ]]; then
            output "   WARNING: Major update available ($tmp)"
         else
            output "   Update $(echo $1 | cut -d":" -f1) from $(echo $1 | cut -d":" -f2) to $tmp"
            sed -i "s|$1|$(echo $1 | cut -d":" -f1):$tmp|g" "$path"
            return
         fi
      done
   fi
}

output () {
   echo -e "$1"
   if [[ "$nolog" != "1" ]]; then
      echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g' >> "$logpath"
   fi
}

createlog () {
   if [[ "$nolog" != "1" ]]; then
      echo "" >> "$logpath"
      output "Log file:                     $logpath"
   else
      output "Log file:                     no log file"
   fi
}

backup () {
   if [[ "$mode" != "0" ]]; then
      output "Backup of current file:       no backup"
      return
   fi
   if [[ "$nobackup" == "1" ]]; then
      output "Backup of current file:       no backup"
      return
   fi
   output "Backup of current file:      $(realpath "$dir/history/$name-$date")"
   cp "$path" "$dir/history/$name-$date"
}

docker-compose-up () {
   if [[ "$containerrestart" == "1" ]]; then
      if [ "$EUID" -ne 0 ]; then
         # script is not run as root
         id -nG "$USER" | grep -qw "docker"
         if [ $? -eq 1 ]; then 
            # user is not part of the group 'docker', command will most likely fail
            output "\033[1;31mERROR: \033[0mRestart of containers not possible. Please run script as root."
            return
         fi
      fi
      output "Load new images and restart corresponding containers..."
      docker-compose -f "$path" up -d
   else
      output "No automatic loading of new images and restart of corresponding containers."
   fi
}

check () {
   
   CONTAINERS=$(docker-compose -f $path config | grep "image: " | cut -d " " -f6)
   #CONTAINERS=$(docker-compose -f $path config | grep "image: " | cut -d " " -f6 | sed -n '4p')
   
   for container in $CONTAINERS; do

      link=$(echo $container | cut -d":" -f1)
      if [[ "$link" != *\/* ]];  then
         link="library/$link"
      fi
   
      tag=$(echo $container | cut -d":" -f2)

      if [[ "$link" =~ "$tag" ]] && [[ "$container" != *":"* ]]; then
         output "$link \033[1;31mMissing tag\033[0m"
         continue
      fi

      output "$link \033[1;34m$tag\033[0m"

      tags=$(curl -s -S "https://registry.hub.docker.com/v2/repositories/$link/tags?ordering=last_updated&page_size=100" | jq '."results"[]["name"]' | tr -d '"' | sort -V -r )

      isfirst="-1"
      count="0"
      newtags=""
      for t in $tags; do

         vercomp $tag $t
         e="$?"      


         # Verbose level 4 - print all tags (max latest 100 tags)
         if [[ "$mode" == "4" ]]; then 
            case "$e" in
               # $tag > $t
               1) output "   \033[1;31m$t\033[0m" ;;
               # $tag < $t
               2) output "   \033[1;32m$t\033[0m" ;;
               # $tag ~ $t
               0|3) output "   \033[1;34m$t\033[0m" ;;
               # default, not comparable or error
               *) output "   \033[1;35m$t\033[0m" ;;
            esac
            continue
         fi 
      
         # Verbose level 3 - print all newer and equal tags 
         if [[ "$mode" == "3" ]]; then
            case "$e" in
               # $tag > $t
               1) ;;
               # $tag < $t
               2) output "   \033[1;32m$t\033[0m" ;;
               # $tag ~ $t 
               0|3) output "   \033[1;34m$t\033[0m" ;;
               # default, not comparable or error
               *)  ;;
            esac
            continue
         fi

         # Verbose level 2 - print all newer tags 
         if [[ "$mode" == "2" ]]; then
            case "$e" in
               # $tag > $t
               1) ;;
               # $tag < $t
               2) output "   \033[1;32m$t\033[0m" ;;
               # $tag ~ $t 
               0|3)  ;;
               # default, not comparable or error
               *)  ;;
            esac
            continue
         fi

         # Verbose level 1 - print only newest tag 
         if [[ "$mode" == "1" ]]; then
            case "$e" in
               # $tag > $t
               1) ;;
               # $tag < $t
               2) output "   \033[1;32m$t\033[0m" && break ;;
               # $tag ~ $t 
               0|3)  ;;
               # default, not comparable or error
               *)  ;;
            esac
            continue
         fi
      
         # Verbose level 0 - print only newest fitting tag for current and newer major releases
#         if [[ "$e" =~ ^(2|0|3)$  ]]; then 
         if [[ "$e" =~ ^(2)$  ]]; then 
            # check if tags have the same amount of .
            if [[ $(echo $tag | tr -cd '.' | wc -c) == $(echo $t | tr -cd '.' | wc -c) ]]; then
               # check if tags contain no characters
               if [[ $(echo $t | grep -o "[a-zA-Z]" | wc -l) == $(echo $tag | grep -o "[a-zA-Z]" | wc -l) ]]; then 
                  if [[ "$isfirst" == "-1" ]]; then
                     isfirst=$(echo $t | cut -d "." -f1)
                     count=$(($count+1))
                     newtags="$t"
                     if [[ "$t" != "$tag" ]]; then
                        output "   \033[1;32m$t\033[0m"
                     else
                        output "   \033[1;34m$t\033[0m"
                     fi
                  fi
                  if [[ "$(echo $t | cut -d "." -f1)" != "$isfirst" ]]; then
                     isfirst=$(echo $t | cut -d "." -f1)
                     count=$(($count+1))
                     newtags="$newtags|$t"
                     if [[ "$t" != "$tag" ]]; then
                        output "   \033[1;32m$t\033[0m"
                     else
                        output "   \033[1;34m$t\033[0m"
                     fi
                  fi
               fi
            fi 
         fi
      done

      if [[ "$autoupdate" == "1" && "$mode" == "0" ]]; then
         update $container $count $newtags
      fi

      output ""

   done
}

print_usage () {
   echo "Description:"
   echo "  This script checks whether there are newer tags for the used images on docker hub than the"
   echo "  ones currently used. Therefore, each used container must be specified with a tag. The "
   echo "  'latest' tag does not work with this script and should be avoided in general. "
   echo "  Every detail for a tag is possible (e. g. '5' '5.1' '5.1.8'). The script will adapt the "
   echo "  type of detail and will update the tag accordingly."
   echo "  Major updates (e. g. from '5.x.y' to '6.x.y') will not be performed by this script. "
   echo "  However, a note for possible upgrades will be presented. "
   echo 
   echo "Usage:"
   echo "  check4updates.sh [options]"
   echo
   echo "Options:"
   echo "  -f <file>    Specify the DOCKER COMPOSE FILE." 
   echo "                  Default: ./docker-compose.yml"
   echo -e "  -m <mode>    Specify the MODE. The output is color encoded: \033[1;32mnewer\033[0m \033[1;31molder\033[0m \033[1;34mequal\033[0m \033[1;35mnot comparable\033[0m"
   echo "                  Mode 0: list the newest tag for every major release. Used to update tags."
   echo "                  Mode 1: list only the newest tag. (Does not fit the tag detail necessarily.)"
   echo "                  Mode 2: list every tag that is newer than the current one."
   echo "                  Mode 3: list every tag that is newer than the current one or equal."
   echo "                  Mode 4: list the last 100 tags available on docker hub."
   echo "                  Default: 0"
   echo "  -b           Create NO BACKUP of the docker compose file."
   echo "                  Default: off"
   echo "  -l           Create NO LOG."
   echo "                  Default: off"
   echo "  -u	        NO UPDATE of tags in docker compose file. Only with Mode 0."
   echo "                  Default: off"
   echo "  -r 	        RESTART containers by loading new images an restart correspoding containers."
   echo "                  Default: off"
   echo "  -s           Include NON STABLE versions containing 'rc', 'beta' or similar."
   echo "                  Default: off"
   echo "  -h           Print this HELP."
   echo
   echo "Examples:"
   echo "  check4updates.sh -u"
   echo "  check4updates.sh -v 4 -l -f /data/docker/docker-compose-yml"
   echo "  check4updates.sh -b -f ./docker-compose.yml"
}

setup () {
   if [[ "$path" == "" ]]; then
      path="$(pwd)/docker-compose.yml"
   else 
      path="$(realpath $path)"
   fi

   name=$( echo "$path" | cut -d'/' -f$((1+$(echo "$path" | tr -cd '/' | wc -c))))
   dir=$( echo "$path" | cut -d'/' -f1-$(echo "$path" | tr -cd '/' | wc -c))
   logpath="$dir/history/log-$date"
}

printheader () {
   output "Current time:                 $date"
   output "Docker-Compose file:          $path"
   output "Mode:                         $mode"
   if [[ "$autoupdate" == "1" ]]; then
      output "Update tags:                  yes"
   else
      output "Update tags:                  no"
   fi
   if [[ "$containerrestart" == "1" ]]; then
      output "Load and restart container:   yes"
   else
      output "Load and restart container:   no"
   fi
   if [[ "$nonstable" == "1" ]]; then
      output "Include non stable versions:  yes"
   else
      output "Include non stable versions:  no"
   fi
}


main () {
   output "#-------------------- Setup --------------------#"
   printheader
   backup
   createlog
   output "#-------------------- Start --------------------#"
   output ""
   check
   output "#-------------------- Finish -------------------#"
   docker-compose-up
   output "#--------------------- End ---------------------#"
}

testcomp () {
   echo "Testmode:"
   #nonstable="1"

   for l in $(cat version-tests.txt); do
      name=$(echo $l | cut -d "|" -f1)
      current=$(echo $l | cut -d "|" -f2)
      #current="12.2.13-ce.0"
      tag=$(echo $l | cut -d "|" -f3)
      state=$(echo $l | cut -d "|" -f4)

      if [[ "$name" == "break" ]]; then
         break
      fi


# compare two versions, return values:
#  0 : versions are idetical
#  1 : $1 > $2
#  2 : $1 < $2
#  3 : $1 and $2 have different details 
#  4 : $1 and $2 are not coperable
#  5 : $2 is not a stable version
# -1 : something went wrong

      vercomp $current $tag
      e="$?"
     
      #if [[ "$e" == "$state" ]]; then
      #   continue
      #fi
 
      case "$e" in
         # $current = $tag
         0) echo -e "$name   $current   \033[1;34m      =       \033[0m   $tag" ;;
         # $current > $tag
         1) echo -e "$name   $current   \033[1;31m      >       \033[0m   $tag" ;;
         # $current < $tag
         2) echo -e "$name   $current   \033[1;32m      <       \033[0m   $tag" ;;
         # $current ~ $tag
         3) echo -e "$name   $current   \033[1;34m      ~       \033[0m   $tag" ;;
         # default, not comparable or error
         4) echo -e "$name   $current   \033[1;35mnot comparable\033[0m   $tag" ;;
         # default, not comparable or error
         5) echo -e "$name   $current   \033[1;35m  not stable  \033[0m   $tag" ;;
         # default, not comparable or error
         *) echo -e "$name   $current   \033[1;35m    error     \033[0m   $tag" ;;
      esac
      
   done

}


while getopts 'f:m:blursth' flag; do
   case "${flag}" in
     f) path="${OPTARG}" ;;
     m) mode="${OPTARG}" ;;
     b) nobackup="1" ;;
     l) nolog="1" ;;
     u) autoupdate="0" ;;
     r) containerrestart="1" ;;
     s) nonstable="1" ;;
     t) testcomp
        exit 0 ;;
     h) print_usage
        exit 1 ;;
     *) print_usage
        exit 1 ;;
   esac
done

setup
main
