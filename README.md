Karaoke Augmentation
====================

When a MIDI file exists but doesn't have lyrics in it, consider an augmentation!

Extraction
----------

$ pike augment.pike --extract some_karaoke_file.kar
Find the channels it uses
$ pike augment.pike --extract=1,4-5,7 some_karaoke_file.kar >lyrics_file.txt
Actually do the tracked extraction, using whichever channels carry relevant notes
(this will ensure correct hyphenation)
