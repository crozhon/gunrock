#!/bin/bash

OPTION="--undirected --src=largestdegree --traversal-mode=LB_CULL --iteration-num=10 --random-edge-value"
MARK=".skip_pred.undir.LB_CULL.32bitSizeT"
EXECUTION="./bin/test_sssp_7.5_x86_64"
DATADIR="../../dataset/large"

NAME[ 0]="soc-twitter-2010"  
NAME[ 1]="hollywood-2009"    
NAME[ 2]="soc-sinaweibo"     
NAME[ 3]="soc-orkut"
NAME[ 4]="soc-LiveJournal1"
NAME[ 5]="uk-2002"
NAME[ 6]="uk-2005"
NAME[ 7]="webbase-2001"
NAME[ 8]="indochina-2004"
NAME[ 9]="arabic-2005"
NAME[10]="europe_osm"
NAME[11]="asia_osm"
NAME[12]="germany_osm"
NAME[13]="road_usa"
NAME[14]="road_central"

cd ~/Projects/gunrock_dev/gunrock/tests/sssp

for d in 2 #{1..6}
do
    SUFFIX="CentOS6_6.k40cx${d}.rand"
    mkdir -p eval/$SUFFIX
    DEVICE="0"
    for i in {1..8}
    do
        if [ "$i" -lt "$d" ]; then
            DEVICE=$DEVICE",$i"
        fi
    done
    QUEUE_SIZING=1.2 #$(echo "${d}+1" | bc)

    for i in 9 #{0..14}
    do
        echo $EXECUTION market $DATADIR/${NAME[$i]}/${NAME[$i]}.mtx $OPTION --queue-sizing=$QUEUE_SIZING --device=$DEVICE --jsondir=./eval/$SUFFIX "> ./eval/$SUFFIX/${NAME[$i]}${MARK}.txt"
             $EXECUTION market $DATADIR/${NAME[$i]}/${NAME[$i]}.mtx $OPTION --queue-sizing=$QUEUE_SIZING --device=$DEVICE --jsondir=./eval/$SUFFIX > ./eval/$SUFFIX/${NAME[$i]}${MARK}.txt
        sleep 1
    done
done

