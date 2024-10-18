/*
Take a MIDI file and a file of lyrics, and build a Karaoke file.

The lyrics file consists of lines of text and directives specifying either the track or channel
to be followed.
*/
object midilib = (object)"patchpatch.pike"; //If not found, copy or symlink from Rosuav's shed
mapping args; //Parsed version of argv[]

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
	array channelnotes = allocate(16, ({ }));
	array lyrics = ({ });
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
			if (cmd >= 0x90 && cmd <= 0x9F && data[3]) {notes += ({pos}); channelnotes[cmd&15] += ({pos});}
			else if (cmd == 255) {
				//Meta events. Some are interesting.
				int meta_type = data[2];
				switch (meta_type) {
					case 3: label = data[3]; break;
					case 5: if (sizeof(String.trim(data[3]))) {have_lyrics = 1; lyrics += ({({pos, data[3]})});} break;
					case 1:
						if (pos > 0) {text_after_start = 1; lyrics += ({({pos, data[3]})});}
						else if (!label) label = data[3];
						break;
					case 0x58: {
						//TODO: Figure out the number of MIDI clocks per bar
						//Build up a map of bar numbers
						//Allow lyrics to be aligned to a specific bar, eg "skip to bar 42"
						//Should be less error-prone than counting hyphens in long sections.
						[int nn, int dd, int cc, int bb] = (array)data[3];
						werror("Time sig [%d] %d/%d, %d, %d\n", pos, nn, 1<<dd, cc, bb);
					}
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
	//Dump channel usage if it's needed (usually uninteresting)
	//foreach (channelnotes; int c; array notes) if (sizeof(notes)) werror("Channel %2d: %d notes\n", c + 1, sizeof(notes));
	//Hack: "Channel" assignments are done by pretending there are sixteen additional chunks after the tracks.
	int firstchannel = sizeof(tracknotes);
	tracknotes += channelnotes;
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
	void select_tracks(string tracks, int(1bit) by_channel) {
		int ofs = by_channel && firstchannel - 1;
		active_tracks = (<>);
		//Usage: "@track 3" or "@track 3,5,6" or "@track 4-7" etc
		//Note that track 0 is not valid; chunk 0 is the MThd, not a track.
		foreach (tracks / ",", string t) {
			t = String.trim(t);
			if (sscanf(t, "%d-%d", int start, int stop) && start && stop)
				for (int i = start; i <= stop; ++i) active_tracks[i + ofs] = 1;
			else if ((int)t) active_tracks[(int)t + ofs] = 1;
		}
		//The common case where there's only one active track has a fast path in nextpos.
		singletrack = sizeof(active_tracks) == 1 && ((array)active_tracks)[0];
		//Skip past any note positions that we're already beyond
		foreach (active_tracks; int t;)
			while (next[t] < stop[t] && tracknotes[t][next[t]] <= pos) ++next[t];
	}
	if (string tracks = args->extract) {
		//Usage: --extract=2-3 equivalent to "@track 2-3" in reverse
		if (sscanf(tracks, "c%s", tracks)) select_tracks(tracks, 1);
		else select_tracks(tracks, 0);
		int lnext = 0, lstop = sizeof(lyrics);
		string ws = ""; //Move whitespace after any hyphens
		while (int p = nextpos()) {
			int done = 0;
			while (lnext < lstop && lyrics[lnext][0] <= p) {
				done = 1;
				string syl = lyrics[lnext++][1];
				if (ws == " " && syl != "" && lower_case(syl) != syl) ws = "\n"; //Hack: Split into paragraphs automatically
				write("%s", ws); ws = "";
				//Any trailing whitespace - and yes, in MIDI Karaoke, that includes slash and backslash -
				//gets moved after any hyphens. Also it won't get turned into an underscore.
				if (syl != "" && has_value(" \r\n\\/", syl[-1])) {ws = syl[<0..]; syl = syl[..<1];}
				//Any embedded spaces or hyphens need to be replaced.
				syl = replace(syl, ([" ": "_", "-": "\u2010"])); //The distinction between U+2010 HYPHEN and U+002D HYPHEN-MINUS is easy to lose, but may be sufficient.
				write("%s", string_to_utf8(syl));
			}
			if (ws == "" || !done) write("-");
		}
		while (lnext < lstop) write("%s", lyrics[lnext++][1]);
		write("\n");
		return;
	}
	array events = ({ });
	int excess_syllables = 0;
	foreach ((Stdio.read_file(text) || "") / "\n", string line) {
		if (has_prefix(line, ";")) continue;
		if (sscanf(line, "@track %s", string tracks) && tracks) {
			if (sscanf(tracks, "channel %s", tracks)) select_tracks(tracks, 1);
			else select_tracks(tracks, 0);
			continue;
		}
		if (line == "") continue; //TODO: Mark an end-of-paragraph on the previous lyric entry rather than end-of-line
		foreach (line / " ", string word) {
			foreach (word / "-", string syl) {
				int p = nextpos();
				if (!p) {++excess_syllables; continue;}
				//TODO: Suppress empty lyric entries?
				events += ({({p - pos, 255, 5, replace(replace(syl, "\u2010", "-"), "_", " ")})});
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
		werror("Saved to %s\n", out);
	}
	if (excess_syllables) werror("\x1b[1;31m-- %d excess syllables with no notes to go with them --\x1b[0m\n", excess_syllables);
	else {
		int excess_notes = 0;
		while (nextpos()) ++excess_notes;
		if (excess_notes) werror("\x1b[1;34m-- %d notes without lyrics --\x1b[0m\n", excess_notes);
	}
}

int main(int argc, array(string) argv) {
	//TODO: Allow elision of some file names, figure it out from context
	args = Arg.parse(argv);
	string mididir = args->dir || args->d || ".";
	string outdir = args->output || args->o || ".";
	mididir = replace(mididir, "~", System.get_home()); //Not supporting "~user" notation
	outdir = replace(outdir, "~", System.get_home());
	if (!sizeof(args[Arg.REST])) exit(1, "USAGE: pike %s [-d=mididir] [-o=outdir] textfile\n");
	array midis = args->partial && filter(get_dir(mididir), has_suffix, ".mid");
	foreach (args[Arg.REST], string fn) {
		werror("## %s\n", fn);
		if (has_suffix(fn, ".mid")) {augment(fn, "-", "-"); continue;} //Quick analysis of a MIDI file
		string midi = mididir + "/" + replace(fn, ".txt", ".mid");
		string out = outdir + "/" + replace(fn, ".txt", ".kar");
		if (midis) {
			//In partial mode, the text file name must only be contained within
			//the MIDI file name, rather than being the whole thing.
			array matches = filter(midis, has_value, fn - ".txt");
			if (sizeof(matches) == 1) {
				midi = mididir + "/" + matches[0];
				out = outdir + "/" + replace(matches[0], ".mid", ".kar");
			}
			else if (!sizeof(matches)) werror("\x1b[1;31m-- no matching MIDI file --\x1b[0m\n");
			else werror("\x1b[1;34m-- multiple matching MIDI files --\x1b[0m\n");
		}
		augment(midi, fn, out);
	}
	if (args->copy) {
		//Copy in files from the mididir to the outdir if there's no corresponding output file
		//Also purge any *.mid from outdir where there IS a corresponding *.kar.
		multiset out = (multiset)get_dir(outdir);
		foreach (sort(get_dir(mididir)), string mid) if (has_suffix(mid, ".mid")) {
			string kar = mid[..<4] + ".kar";
			if (out[kar] && out[mid]) {
				werror("Cleaning out %s\n", mid);
				rm(outdir + "/" + mid);
			}
			if (!out[kar] && !out[mid]) {
				werror("Copying %s\n", mid);
				Stdio.write_file(outdir + "/" + mid, Stdio.read_file(mididir + "/" + mid));
			}
		}
	}
}
