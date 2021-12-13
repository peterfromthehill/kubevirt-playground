#!/bin/bash

function parse_yaml {
   local prefix=$2
   local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
   sed -ne "s|^\($s\):|\1|" \
        -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
   awk -F$fs '{
      indent = length($1)/2;
      vname[indent] = $2;
      for (i in vname) {if (i > indent) {delete vname[i]}}
      if (length($3) > 0) {
         vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
         printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
      }
   }'
}

echo $@

eval "cat <<EOF
$(<cloudinit.yaml)
EOF
" | kubectl apply -f -
for host in $@; do
  eval "cat <<EOF
$(<${host})
EOF
" | kubectl apply -f -
done

for host in $@; do
  eval $(parse_yaml $host)
  virtctl -n $metadata_namespace stop $metadata_name
done
for host in $@; do
  eval $(parse_yaml $host)
  while test $(kubectl -n $metadata_namespace get vm $metadata_name -o jsonpath='{.status.printableStatus}') != Stopped;
  do 
   echo -n .
  done
done
for host in $@; do
  eval $(parse_yaml $host)
  virtctl -n $metadata_namespace start $metadata_name
done
