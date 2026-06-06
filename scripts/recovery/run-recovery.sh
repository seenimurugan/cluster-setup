#!/bin/bash
# Read-only PhotoRec carve of whole 3TB SEENI HDD (My Passport) -> Mac HD.
# Photos+videos: jpg, heic/heif+mov/mp4 (mov), png, gif, tiff+raw (tif), bmp, mpg, mkv, orf, rw2, raf.
cd /Users/nila/SEENI-recovery || exit 1
exec photorec /log /d /Users/nila/SEENI-recovery/recup /cmd /dev/rdisk5 partition_none,fileopt,everything,disable,jpg,enable,mov,enable,png,enable,gif,enable,tif,enable,bmp,enable,mpg,enable,mkv,enable,orf,enable,rw2,enable,raf,enable,search
