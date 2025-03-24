/*
Take a MIDI file and a file of lyrics, and build a Karaoke file.

The lyrics file consists of lines of text and directives specifying either the track or channel
to be followed.
*/
object midilib = (object)"patchpatch.pike"; //If not found, copy or symlink from Rosuav's shed
mapping args; //Parsed version of argv[]

constant boringmetaevents = ([ //Everything here is considered uninteresting and is silently kept.
	0x02: "Copyright",
	0x04: "Instrument",
	0x21: "MIDI port",
	0x2F: "End of track",
	0x51: "Tempo",
	0x58: "Time sig",
	0x59: "Key sig",
]);

void augment(string midi, string text, string out, int(1bit)|void compare) {
	array(array(string|array(array(int|string)))) chunks;
	if (catch {chunks = midilib->parsesmf(Stdio.read_file(midi));}) return;
	array tracknotes = allocate(sizeof(chunks), ({ }));
	array channelnotes = allocate(16, ({ }));
	array lyrics = ({ });
	sscanf(chunks[0][1], "%2c%2c%2c", int miditype, int chunkcount, int ppqn);
	int bar_length = ppqn * 4; //Default is 4/4 time, 24 clocks per quarter note
	array bar_starts = ({0, 0}); //Allow 1-based indexing since that's how humans think (bar_starts[1] is the position where bar #1 starts)
	mapping channelchunks = ([]);
	foreach (chunks; int i; [string id, array chunk]) if (id == "MTrk") {
		//TODO: Scan the chunk for either lyrics or text. If any lyrics found,
		//ignore all text. Otherwise, if any text found after the start, use text.
		//Also show which channels have note-related messages.
		int(1bit) have_lyrics = 0, text_after_start = 0;
		int pos = 0;
		string|zero label;
		array notes = ({ });
		multiset chunkchannels = (<>);
		foreach (chunk; int ev; array data) {
			//data == ({delay, command[, args...]})
			pos += data[0];
			while (pos >= bar_starts[-1] + bar_length) bar_starts += ({bar_starts[-1] + bar_length});
			int cmd = data[1];
			if (cmd >= 0x90 && cmd <= 0x9F && data[3]) {notes += ({pos}); channelnotes[cmd&15] += ({pos}); chunkchannels[1 + (cmd&15)] = 1;}
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
						int barlen = ((ppqn / bb) << (5 - dd)) * nn;
						if (int residue = pos - bar_starts[-1]) {
							//If there's a time sig part way through a bar, predict the next
							//bar position by presuming that we are proportionally through
							//the current bar. That is, if we were 25% through, count 75%
							//of the new bar length and mark the next bar there. This won't
							//work if there are TWO time sigs inside the same bar, but...
							//don't do that. Actually, just don't have a time sig within a
							//bar anyway. It's not a normal thing.
							int rest = barlen * (bar_length - residue) / bar_length;
							werror("\e[1;33mTime sig part way in (%d/%d), adding %d/%d for rest of bar\e[0m\n",
								residue, bar_length, rest, barlen);
							bar_starts += ({pos + rest});
						}
						bar_length = barlen;
						//werror("Time sig [%d] %d/%d, %d, %d, ppqn %d \e[1;35mBar length: %d\e[0m\n", pos, nn, 1<<dd, cc, bb, ppqn, bar_length);
					}
					default:
						if (!boringmetaevents[meta_type])
							werror("[%d:%d] %d ==> Meta %X %O\n", i, ev, data[0], data[2], data[3]);
				}
			}
			//else werror("[%d:%d] %d ==>%{ %X%}\n", i, ev, data[0], data[1..]); //Log unknown events if there's anything weird to track down
		}
		string lyrics = have_lyrics ? "lyrics" : text_after_start ? "text" : "wordless";
		werror("Track %2d [%s]: %s (c%{ %d%})\n", i, lyrics, label || "Unlabelled", sort((array)chunkchannels));
		//if (sizeof(notes)) werror(" - %d notes starting at %d\n", sizeof(notes), notes[0]);
		tracknotes[i] = notes;
		foreach (chunkchannels; int chan;) channelchunks[chan] |= (<i>);
	}
	//Dump channel usage if it's needed (usually uninteresting)
	//foreach (channelnotes; int c; array notes) if (sizeof(notes)) werror("Channel %2d: %d notes\n", c + 1, sizeof(notes));
	//Hack: "Channel" assignments are done by pretending there are sixteen additional chunks after the tracks.
	int firstchannel = sizeof(tracknotes);
	tracknotes += channelnotes;
	//Okay. So. Let's have a look at the file. We will build a new chunk for the lyrics.
	multiset active_tracks = (<>); int singletrack = 0;
	multiset all_active_tracks = (<>); //Every track that's ever been active
	int pos = 0;
	int minnote = 0;
	//Next and Last indices within each track. So long as next[n] < stop[n], you can draw content from track n.
	array next = allocate(sizeof(tracknotes)), stop = sizeof(tracknotes[*]);
	void skipto(int p) {
		foreach (active_tracks; int t;)
			while (next[t] < stop[t] && tracknotes[t][next[t]] <= p) ++next[t];
	}
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
		//equality? If you want a buffer zone, set minnote to a nonzero value.)
		if (best <= pos) return 0;
		skipto(best + minnote);
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
		if (by_channel) foreach (active_tracks; int t;) all_active_tracks |= channelchunks[t - ofs];
		else all_active_tracks |= active_tracks;
		//The common case where there's only one active track has a fast path in nextpos.
		singletrack = sizeof(active_tracks) == 1 && ((array)active_tracks)[0];
		//Skip past any note positions that we're already beyond
		skipto(pos);
	}
	if (string tracks = args->extract) {
		//Usage: --extract=2-3 equivalent to "@track 2-3" in reverse
		if (intp(tracks)) tracks = "";
		if (sscanf(tracks, "c%s", tracks)) {write("@track channel %s\n", tracks); select_tracks(tracks, 1);}
		else {write("@track %s\n", tracks); select_tracks(tracks, 0);}
		int lnext = 0, lstop = sizeof(lyrics);
		string ws = ""; //Move whitespace after any hyphens
		int linecount = 0;
		//if (sizeof(lyrics)) werror("Lyrics start %d\n", lyrics[0][0]);
		while (int p = nextpos()) {
			int done = 0;
			while (lnext < lstop && lyrics[lnext][0] <= p) {
				done = 1;
				string syl = lyrics[lnext++][1];
				//Hack: Split into paragraphs automatically. After we've seen at least a few
				//syllables, the next syllable that starts with a capital letter (or includes
				//one - for example, "[Chorus]") will be put onto its own line. TODO: Only do
				//this if there are no actual newlines in the lyrics.
				if (ws == " " && syl != "" && lower_case(syl) != syl && linecount >= 5) ws = "\n";
				if (ws == "\n") linecount = 0; else ++linecount;
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
	mapping gaps = ([]);
	foreach ((utf8_to_string(Stdio.read_file(text) || "")) / "\n", string line) {
		if (has_prefix(line, ";")) continue;
		if (sscanf(line, "@track %s", string tracks) && tracks) {
			if (sscanf(tracks, "channel %s", tracks)) select_tracks(tracks, 1);
			else select_tracks(tracks, 0);
			continue;
		}
		if (sscanf(line, "@minnote %d", minnote)) continue; //Note that "@minnote 0" is valid, and will reset the limit to its default of zero.
		if (line == "") continue; //TODO: Mark an end-of-paragraph on the previous lyric entry rather than end-of-line
		int shortest = 1<<30, longest = 0;
		int first = 1;
		foreach (line / " ", string word) {
			foreach (word / "-", string syl) {
				if (sscanf(syl, "{%d%[<]}", int bar, string allbut)) {
					//Skip to bar N. If this is followed by a hyphen,
					//we won't add a space yet; otherwise, the next word will
					//start at the start of bar N.
					//Add one or more "<" to leave notes behind - currently works only in single-track mode.
					//To expand it to work more flexibly, we'd need to recreate the nextpos() logic, but
					//without actually advancing next[] in any track.
					if (sizeof(allbut)) {
						if (!singletrack) error("{bar<} usage only valid in singletrack mode for now\n");
						//Quick check: If we were to skip to the start of that bar, would we run past
						//the end of this track?
						if (bar_starts[bar] >= tracknotes[singletrack][stop[singletrack] - 1]) error("Can't skip to that bar\n");
						//Okay. So now we scan to that point, retaining the last N positions.
						int n = next[singletrack];
						array pos = ({ });
						array tn = tracknotes[singletrack];
						for (int i = 0; i < sizeof(allbut); ++i) pos += ({tn[n++]});
						while (tn[n] < bar_starts[bar]) pos = pos[1..] + ({tn[n++]});
						//We now have N positions recorded. The next position after this (tn[n]) is the
						//first note after the bar line, and pos[] contains the N positions just prior
						//to it. Which means, the position N notes prior is the first thing in the array.
						//So we can skip to just before that note starts, as per the logic of skipping to bar.
						skipto(pos[0] - 1);
						continue;
					}
					skipto(bar_starts[bar] - 1); //Skip to just before the bar starts, so the next lyric entry takes the bar start
					continue;
				}
				int p = nextpos();
				if (!p) {++excess_syllables; continue;}
				gaps[p - pos]++;
				if (!first) {shortest = min(shortest, p - pos); longest = max(longest, p - pos);}
				first = 0;
				//TODO: Suppress empty lyric entries?
				events += ({({p - pos, 255, 5, replace(replace(syl, "\u2010", "-"), "_", " ")})});
				pos = p;
			}
			if (!excess_syllables) events[-1][-1] += " ";
		}
		if (!excess_syllables) events[-1][-1] = String.trim(events[-1][-1]) + "\n";
		//werror("Gap %3d - %3d %O\n", shortest, longest, line);
	}
	if (args->gaps) werror("Lyric gap heatmap (clocks:count): %O\n", gaps);
	if (sizeof(events)) {
		events = ({({0, 255, 3, "Lyrics"})}) + events + ({({0, 255, 0x2F, ""})});
		sscanf(chunks[0][1], "%2c%2c%2c", int typ, int trks, int timing);
		chunks[0][1] = sprintf("%2c%2c%2c", typ, trks + 1, timing);
		Stdio.write_file(out, midi = midilib->buildsmf(chunks + ({({"MTrk", events})})));
		//Stdio.write_file(out, midilib->buildsmf(({chunks[0]}) + ({({"MTrk", events})}) + chunks[1..]));
		werror("Saved to %s\n", out);
	}
	if (excess_syllables) werror("\x1b[1;31m-- %d excess syllables with no notes to go with them --\x1b[0m\n", excess_syllables);
	else {
		int excess_notes = 0;
		while (nextpos()) ++excess_notes;
		if (excess_notes) werror("\x1b[1;34m-- %d notes without lyrics --\x1b[0m\n", excess_notes);
	}
	if (compare) {
		//TODO: Merge in the effect of midichannelreduce rather than calling on it
		//The --merge hack in there would only be needed here.
		object mcr = (object)"../../shed/midichannelreduce.pike";
		all_active_tracks[1] = 1; //Always take the conductor track
		string data = mcr->reduce(midi, all_active_tracks, (<>), 1, 1);
		mapping rc = Process.run(({"midi2ly", "--duration-quant=16", "--start-quant=16", "-o", "compare.ly", "/dev/stdin"}), (["stdin": data]));
		Process.run(({"lilypond", "compare.ly"}), (["stdin": rc->stdout]));
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
	mapping files = ([]);
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
		files[fn] = ({midi, out});
		augment(midi, fn, out, args->compare);
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
	if (args->watch) {
		//Note that this will not watch for new files, since that would require that we do our own globbing.
		//It just monitors changes to the files that it already processed.
		object inot = System.Inotify.Instance();
		inot->add_watch(indices(files)[*], System.Inotify.IN_CLOSE_WRITE) {
			[int event, int cookie, string path] = __ARGS__;
			if (!files[path]) return;
			[string midi, string out] = files[path];
			augment(midi, path, out, args->compare);
		};
		return -1;
	}
}
