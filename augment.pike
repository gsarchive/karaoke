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
	array tracknotes = allocate(sizeof(chunks), ({ }));
	foreach (chunks; int i; [string id, array chunk]) if (id == "MTrk") {
		//TODO: Scan the chunk for either lyrics or text. If any lyrics found,
		//ignore all text. Otherwise, if any text found after the start, use text.
		//Also show which channels have note-related messages.
		int(1bit) have_lyrics = 0, text_after_start = 0;
		int pos = 0;
		string|zero label;
		array notes = ({ });
		foreach (chunk; int ev; array data) {
			//data == ({delay, command[, args...]})
			pos += data[0];
			int cmd = data[1];
			if (cmd >= 0x90 && cmd <= 0x9F && data[3]) notes += ({pos});
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
		string lyrics = have_lyrics ? "lyrics" : text_after_start ? "text" : "wordless";
		werror("Track %2d [%s]: %s\n", i, lyrics, label || "Unlabelled");
		//if (sizeof(notes)) werror(" - %d notes starting at %d\n", sizeof(notes), notes[0]);
		tracknotes[i] = notes;
	}
	//Okay. So. Let's have a look at the file. We will build a new chunk for the lyrics.
	multiset active_tracks = (<>); int singletrack = 0;
	int pos = 0;
	//Next and Last indices within each track. So long as next[n] < stop[n], you can draw content from track n.
	array next = allocate(sizeof(tracknotes)), stop = sizeof(tracknotes[*]);
	int nextpos() { //Return the next position of any note-on in any active track, or 0 if none.
		if (singletrack) return next[singletrack] < stop[singletrack] && tracknotes[singletrack][next[singletrack]++];
		//Scan multiple tracks, find the earliest, use it.
		int best = 0;
		foreach (active_tracks; int t;)
			if (next[t] < stop[t] && (!best || tracknotes[t][next[t]] < best))
				best = tracknotes[t][next[t]];
		//Advance past everything at this point. That isn't necessarily just the one
		//track that we found this in; if other tracks have notes at precisely the same
		//point, we skip past those too. (Should there be a small buffer zone or just
		//equality? Using simple equality for the moment.)
		if (best <= pos) return 0;
		foreach (active_tracks; int t;)
			while (next[t] < stop[t] && tracknotes[t][next[t]] <= best) ++next[t];
		return best;
	}
	array events = ({ });
	int excess_syllables = 0;
	foreach ((Stdio.read_file(text) || "") / "\n", string line) {
		if (has_prefix(line, ";")) continue;
		if (sscanf(line, "@track %s", string tracks) && tracks) {
			active_tracks = (<>);
			//Usage: "@track 3" or "@track 3,5,6" or "@track 4-7" etc
			//Note that track 0 is not valid; chunk 0 is the MThd, not a track.
			foreach (tracks / ",", string t) {
				t = String.trim(t);
				if (sscanf(t, "%d-%d", int start, int stop) && start && stop)
					for (int i = start; i <= stop; ++i) active_tracks[i] = 1;
				else if ((int)t) active_tracks[(int)t] = 1;
			}
			//The common case where there's only one active track has a fast path in nextpos.
			singletrack = sizeof(active_tracks) == 1 && ((array)active_tracks)[0];
			//Skip past any note positions that we're already beyond
			foreach (active_tracks; int t;)
				while (next[t] < stop[t] && tracknotes[t][next[t]] <= pos) ++next[t];
			continue;
		}
		if (line == "") continue; //TODO: Mark an end-of-paragraph on the previous lyric entry rather than end-of-line
		foreach (line / " ", string word) {
			foreach (word / "-", string syl) {
				int p = nextpos();
				if (!p) {++excess_syllables; continue;}
				events += ({({p - pos, 255, 5, replace(syl, "_", " ")})});
				pos = p;
			}
			if (!excess_syllables) events[-1][-1] += " ";
		}
		if (!excess_syllables) events[-1][-1] = String.trim(events[-1][-1]) + "\n";
	}
	if (sizeof(events)) {
		events = ({({0, 255, 3, "Lyrics"})}) + events + ({({0, 255, 0x2F, ""})});
		sscanf(chunks[0][1], "%2c%2c%2c", int typ, int trks, int timing);
		chunks[0][1] = sprintf("%2c%2c%2c", typ, trks + 1, timing);
		Stdio.write_file(out, midilib->buildsmf(chunks + ({({"MTrk", events})})));
		//Stdio.write_file(out, midilib->buildsmf(({chunks[0]}) + ({({"MTrk", events})}) + chunks[1..]));
		write("Saved to %s\n", out);
	}
	if (excess_syllables) write("-- %d excess syllables with no notes to go with them --\n", excess_syllables);
	else {
		int excess_notes = 0;
		while (nextpos()) ++excess_notes;
		if (excess_notes) write("-- %d notes without lyrics --\n", excess_notes);
	}
}

int main(int argc, array(string) argv) {
	//TODO: Allow elision of some file names, figure it out from context
	mapping args = Arg.parse(argv);
	string mididir = args->dir || args->d || ".";
	string outdir = args->output || args->o || ".";
	mididir = replace(mididir, "~", System.get_home()); //Not supporting "~user" notation
	outdir = replace(outdir, "~", System.get_home());
	if (!sizeof(args[Arg.REST])) exit(1, "USAGE: pike %s [-d=mididir] [-o=outdir] textfile\n");
	foreach (args[Arg.REST], string fn) {
		werror("## %s\n", fn);
		if (has_suffix(fn, ".mid")) {augment(fn, "-", "-"); continue;} //Quick analysis of a MIDI file
		string midi = mididir + "/" + replace(fn, ".txt", ".mid");
		string out = outdir + "/" + replace(fn, ".txt", ".kar");
		augment(midi, fn, out);
	}
}
