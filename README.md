# sane-backends-1.4.0
Fork of the sane-backends-1.4.0 code


This fork adds the following changes to improve scanning on Nikon Coolscan
1) Adds new ```--adapter``` parameter. The original code was developed against the SA-20 adapter on a LS-30. The used default can lead to misaligned frames when doing batch scans. This fork updates frame offsets for the SA-21 on a LS-50. SA-21 is the new default, add ```--adapter=sa20``` to use the previous defaults. In my testing adding the parameter ```--tl-y 1100``` automatically vertically cropped the images when doing batch scans to the right length. See ```coolscan3-sa21-frame-offset.md``` for details.
2) IR support. The offical source has infrared scanning set to inactive. This fork adds supports for infrared scanning on the LS-50 and LS-5000.

# Instructions

Follow the official Sane project instructions (see http://www.sane-project.org) to build the library and entire project.

# IR Support

To create a seperate image for the raw scan and IR channel you can use the following command:

```scanimage -d <yourdevice> --format=tiff --infrared=yes --depth 8 --resolution 2000 --frame=6 --autofocus --batch=test-%d.tiff --batch-count=2```

It outputs to seperate Tiff files, one with the raw image data and one with the IR channel data.

There are many options to inpaint the seperate IR channel data. 

## Inpaint with Gmic

This project includes a script using [Gmic](https://gmic.eu).

1. Open Terminal and install Gmic ```brew install gmic``` dependency
2. Run ```ir_clean_gmic.sh``` <image-file.tif> <if-file.tif> <output.tif>
