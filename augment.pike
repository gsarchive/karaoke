/*
Take a MIDI file and a file of lyrics, and build a Karaoke file.

The lyrics file consists of lines of text and directives specifying either the track or channel
to be followed.
*/
object midilib = (object)"patchpatch.pike"; //If not found, copy or symlink from Rosuav's shed

constant boringmetaevents = ([ //Everything here is considered uninteresting and is silently kept.
	0x02: "Copyright",
	0x21: "MIDI port",
	0x2F: "End of track",
	0x51: "Tempo",
	0x58: "Time sig",
	0x59: "Key sig",
]);

void augment(string midi, string text, string out) {
	array(array(string|array(array(int|string)))) chunks;
	if (catch {chunks = midilib->parsesmf(Stdio.read_file(midi));}) return;
	foreach (chunks; int i; [string id, array chunk]) if (id == "MTrk") {
		//TODO: Scan the chunk for either lyrics or text. If any lyrics found,
		//ignore all text. Otherwise, if any text found after the start, use text.
		//Also show which channels have note-related messages.
		int(1bit) have_lyrics = 0, text_after_start = 0;
		multiset(int) channels = (<>);
		int pos = 0;
		string|zero label;
		foreach (chunk; int ev; array data) {
			//data == ({delay, command[, args...]})
			pos += data[0];
			int cmd = data[1];
			if (cmd >= 0x80 && cmd <= 0xEF) channels[cmd & 15] = 1;
			else if (cmd == 255) {
				//Meta events. Some are interesting.
				int meta_type = data[2];
				switch (meta_type) {
					case 3: label = data[3]; break;
					case 5: if (sizeof(String.trim(data[3]))) have_lyrics = 1; break;
					case 1:
						if (pos > 0) text_after_start = 1;
						else if (!label) label = data[3];
						break;
					default:
						if (!boringmetaevents[meta_type])
							werror("[%d:%d] %d ==> Meta %X %O\n", i, ev, data[0], data[2], data[3]);
				}
			}
			//else werror("[%d:%d] %d ==>%{ %X%}\n", i, ev, data[0], data[1..]); //Log unknown events if there's anything weird to track down
		}
		string lyrics = have_lyrics ? "lyrics" : text_after_start ? "textty" : "silent";
		werror("Track %2d [%s]: %s\n", i, lyrics, label || "Unlabelled");
	}
}

int main(int argc, array(string) argv) {
	//TODO: Allow elision of some file names, figure it out from context
	if (argc < 4) exit(1, "USAGE: pike %s midi text output\n");
	augment(argv[1], argv[2], argv[3]);
}
