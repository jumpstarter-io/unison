(* Unison file synchronizer: src/copy.ml *)
(* Copyright 1999-2009, Benjamin C. Pierce 

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
*)


let (>>=) = Lwt.bind

let debug = Trace.debug "copy"

(****)

let protect f g =
  try
    f ()
  with Sys_error _ | Unix.Unix_error _ | Util.Transient _ as e ->
    begin try g () with Sys_error _  | Unix.Unix_error _ -> () end;
    raise e

let lwt_protect f g =
  Lwt.catch f
    (fun e ->
       begin match e with
         Sys_error _ | Unix.Unix_error _ | Util.Transient _ ->
           begin try g () with Sys_error _  | Unix.Unix_error _ -> () end
       | _ ->
           ()
       end;
       Lwt.fail e)

(****)

let fileIsTransferred fspathTo pathTo desc fp ress =
  let info = Fileinfo.get false fspathTo pathTo in
  (info,
   info.Fileinfo.typ = `FILE &&
   Props.length info.Fileinfo.desc = Props.length desc
   && Osx.ressLength info.Fileinfo.osX.Osx.ressInfo =
      Osx.ressLength ress
   &&
   let fp' = Os.fingerprint fspathTo pathTo info in
   fp' = fp)

(****)

let removeOldTempFile fspathTo pathTo =
  if Os.exists fspathTo pathTo then begin
    debug (fun() -> Util.msg "Removing old temp file %s / %s\n"
           (Fspath.toDebugString fspathTo) (Path.toString pathTo));
    Os.delete fspathTo pathTo
  end

let openFileIn fspath path kind =
  match kind with
    `DATA -> Fs.open_in_bin (Fspath.concat fspath path)
  | `RESS -> Osx.openRessIn fspath path

let openFileOut fspath path kind len =
  match kind with
    `DATA ->
      let fullpath = Fspath.concat fspath path in
      let flags = [Unix.O_WRONLY;Unix.O_CREAT] in
      let perm = 0o600 in
      begin match Util.osType with
        `Win32 ->
          Fs.open_out_gen
            [Open_wronly; Open_creat; Open_excl; Open_binary] perm fullpath
      | `Unix ->
          let fd =
            try
              Fs.openfile fullpath (Unix.O_EXCL :: flags) perm
            with
              Unix.Unix_error
                ((Unix.EOPNOTSUPP | Unix.EUNKNOWNERR 524), _, _) ->
              (* O_EXCL not supported under a Netware NFS-mounted filesystem.
                 Solaris and Linux report different errors. *)
                Fs.openfile fullpath (Unix.O_TRUNC :: flags) perm
          in
          Unix.out_channel_of_descr fd
      end
  | `RESS ->
      Osx.openRessOut fspath path len

let setFileinfo fspathTo pathTo realPathTo update desc =
  match update with
    `Update _ -> Fileinfo.set fspathTo pathTo (`Copy realPathTo) desc
  | `Copy     -> Fileinfo.set fspathTo pathTo (`Set Props.fileDefault) desc

(****)

let copyContents fspathFrom pathFrom fspathTo pathTo fileKind fileLength ido =
  let use_id f = match ido with Some id -> f id | None -> () in
  let inFd = openFileIn fspathFrom pathFrom fileKind in
  protect
    (fun () ->
       let outFd = openFileOut fspathTo pathTo fileKind fileLength in
       protect
         (fun () ->
            Uutil.readWriteBounded inFd outFd fileLength
              (fun l ->
                 use_id (fun id ->
                   Abort.check id;
                   Uutil.showProgress id (Uutil.Filesize.ofInt l) "l"));
            close_in inFd;
            close_out outFd)
         (fun () -> close_out_noerr outFd))
    (fun () -> close_in_noerr inFd)

let localFile
     fspathFrom pathFrom fspathTo pathTo realPathTo update desc ressLength ido =
  let use_id f = match ido with Some id -> f id | None -> () in
  Util.convertUnixErrorsToTransient
    "copying locally"
    (fun () ->
      use_id (fun id -> Uutil.showProgress id Uutil.Filesize.zero "l");
      debug (fun () ->
        Util.msg "Copy.localFile %s / %s to %s / %s\n"
          (Fspath.toDebugString fspathFrom) (Path.toString pathFrom)
          (Fspath.toDebugString fspathTo) (Path.toString pathTo));
      removeOldTempFile fspathTo pathTo;
      copyContents
        fspathFrom pathFrom fspathTo pathTo `DATA (Props.length desc) ido;
      if ressLength > Uutil.Filesize.zero then
        copyContents
          fspathFrom pathFrom fspathTo pathTo `RESS ressLength ido;
      setFileinfo fspathTo pathTo realPathTo update desc)

(****)

(* BCP '06: This is a hack to work around a bug on the Windows platform
   that causes lightweight threads on the server to hang.  I conjecture that
   the problem has to do with the RPC mechanism, which was used here to
   make a call *back* from the server to the client inside Trace.log so that
   the log message would be appended to the log file on the client. *)
(* BCP '08: Jerome thinks that printing these messages using Util.msg
   may be causing the dreaded "assertion failure in remote.ml," which
   happens only on windows and seems correlated with the xferbycopying
   switch.  The conjecture is that some windows ssh servers may combine
   the stdout and stderr streams, which would result in these messages
   getting interleaved with Unison's RPC protocol stream. *)
let loggit s =
  if Prefs.read Globals.someHostIsRunningWindows
    then () (* Util.msg "%s" *)
    else Trace.log s

let tryCopyMovedFile fspathTo pathTo realPathTo update desc fp ress id =
  Prefs.read Xferhint.xferbycopying
    &&
  Util.convertUnixErrorsToTransient "tryCopyMovedFile" (fun() ->
    debug (fun () -> Util.msg "tryCopyMovedFile: -> %s /%s/\n"
      (Path.toString pathTo) (Os.fullfingerprint_to_string fp));
    match Xferhint.lookup fp with
      None ->
        false
    | Some (candidateFspath, candidatePath) ->
        loggit (Printf.sprintf
          "Shortcut: copying %s from local file %s\n"
          (Path.toString realPathTo)
          (Path.toString candidatePath));
        debug (fun () ->
          Util.msg
            "tryCopyMovedFile: found match at %s,%s. Try local copying\n"
            (Fspath.toDebugString candidateFspath)
            (Path.toString candidatePath));
        try
          if Os.exists candidateFspath candidatePath then begin
            localFile
              candidateFspath candidatePath fspathTo pathTo realPathTo
              update desc (Osx.ressLength ress) (Some id);
            let (info, isTransferred) =
              fileIsTransferred fspathTo pathTo desc fp ress in
            if isTransferred then begin
              debug (fun () -> Util.msg "tryCopyMoveFile: success.\n");
              Xferhint.insertEntry (fspathTo, pathTo) fp;
              true
            end else begin
              debug (fun () ->
                Util.msg "tryCopyMoveFile: candidate file modified!");
              Xferhint.deleteEntry (candidateFspath, candidatePath);
              Os.delete fspathTo pathTo;
              loggit (Printf.sprintf
                "Shortcut didn't work because %s was modified\n"
                (Path.toString candidatePath));
              false
            end
          end else begin
            loggit (Printf.sprintf
              "Shortcut didn't work because %s disappeared!\n"
              (Path.toString candidatePath));
            Xferhint.deleteEntry (candidateFspath, candidatePath);
            false
          end
        with
          Util.Transient s ->
            debug (fun () ->
              Util.msg "tryCopyMovedFile: local copy didn't work [%s]" s);
            Xferhint.deleteEntry (candidateFspath, candidatePath);
            Os.delete fspathTo pathTo;
            loggit (Printf.sprintf
              "Local copy of %s failed\n"
              (Path.toString candidatePath));
            false)

(****)

(* The file transfer functions here depend on an external module
   'transfer' that implements a generic transmission and the rsync
   algorithm for optimizing the file transfer in the case where a
   similar file already exists on the target. *)

let rsyncActivated =
  Prefs.createBool "rsync" true
    "!activate the rsync transfer mode"
    ("Unison uses the 'rsync algorithm' for 'diffs-only' transfer "
     ^ "of updates to large files.  Setting this flag to false makes Unison "
     ^ "use whole-file transfers instead.  Under normal circumstances, "
     ^ "there is no reason to do this, but if you are having trouble with "
     ^ "repeated 'rsync failure' errors, setting it to "
     ^ "false should permit you to synchronize the offending files.")

let decompressor = ref Remote.MsgIdMap.empty

let processTransferInstruction conn (file_id, ti) =
  Util.convertUnixErrorsToTransient
    "processing a transfer instruction"
    (fun () ->
       ignore (Remote.MsgIdMap.find file_id !decompressor ti));
  Lwt.return ()

let marshalTransferInstruction =
  (fun (file_id, (data, pos, len)) rem ->
     (Remote.encodeInt file_id :: (data, pos, len) :: rem,
      len + Remote.intSize)),
  (fun buf pos ->
     let len = Bytearray.length buf - pos - Remote.intSize in
     (Remote.decodeInt buf pos, (buf, pos + Remote.intSize, len)))

let processTransferInstructionRemotely =
  Remote.registerSpecialServerCmd
    "processTransferInstruction" marshalTransferInstruction
    Remote.defaultMarshalingFunctions processTransferInstruction

let blockInfos = ref Remote.MsgIdMap.empty

let compress conn
     (biOpt, fspathFrom, pathFrom, fileKind, sizeFrom, id, file_id) =
  Util.convertUnixErrorsToTransient "rsync sender"
    (fun () ->
            let infd = openFileIn fspathFrom pathFrom fileKind in
            lwt_protect
              (fun () ->
                 let showProgress count =
                   Abort.check id;
                   Uutil.showProgress id (Uutil.Filesize.ofInt count) "r" in
                 let compr =
                   match biOpt with
                     None     -> Transfer.send infd sizeFrom showProgress
                   | Some bi  -> let remBi =
                                   try
                                     Remote.MsgIdMap.find file_id !blockInfos
                                   with Not_found ->
                                     []
                                 in
                                 let bi = bi :: remBi in
                                 blockInfos :=
                                   Remote.MsgIdMap.remove file_id !blockInfos;
                                 Transfer.Rsync.rsyncCompress
                                   bi infd sizeFrom showProgress
                 in
                 compr
                   (fun ti ->
                      processTransferInstructionRemotely conn (file_id, ti))
                       >>= fun () ->
                 close_in infd;
                 Lwt.return ())
              (fun () ->
                 close_in_noerr infd))

let compressRemotely = Remote.registerServerCmd "compress" compress

let receiveRemBiLocally _ (file_id, bi) =
  let bil =
    try
      Remote.MsgIdMap.find file_id !blockInfos
    with Not_found ->
      []
  in
  blockInfos := Remote.MsgIdMap.add file_id (bi :: bil) !blockInfos;
  Lwt.return ()

let receiveRemBi = Remote.registerServerCmd "receiveRemBi" receiveRemBiLocally
let rec sendRemBi conn file_id remBi =
  match remBi with
    []     -> Lwt.return ()
  | x :: r -> sendRemBi conn file_id r >>= (fun () ->
              receiveRemBi conn (file_id, x))

let close_all infd outfd =
  Util.convertUnixErrorsToTransient
    "closing files"
    (fun () ->
       begin match !infd with
         Some fd -> close_in fd; infd := None
       | None    -> ()
       end;
       begin match !outfd with
         Some fd -> close_out fd; outfd := None
       | None    -> ()
       end)

let close_all_no_error infd outfd =
  begin match !infd with
    Some fd -> close_in_noerr fd
  | None    -> ()
  end;
  begin match !outfd with
    Some fd -> close_out_noerr fd
  | None    -> ()
  end

(* Lazy creation of the destination file *)
let destinationFd fspath path kind len outfd =
  match !outfd with
    None    ->
      let fd = openFileOut fspath path kind len in
      outfd := Some fd;
      fd
  | Some fd ->
      fd

let transferFileContents
      connFrom fspathFrom pathFrom fspathTo pathTo realPathTo update
      fileKind srcFileSize id =
  (* We delay the opening of the file so that there are not too many
     temporary files remaining after a crash *)
  let outfd = ref None in
  let infd = ref None in
  let showProgress count =
    Abort.check id;
    Uutil.showProgress id (Uutil.Filesize.ofInt count) "r" in
  let (bi, decompr) =
    match update with
      `Update (destFileDataSize, destFileRessSize)
          when Prefs.read rsyncActivated
                 &&
               let destFileSize =
                 match fileKind with
                   `DATA -> destFileDataSize
                 | `RESS -> destFileRessSize
               in
               Transfer.Rsync.aboveRsyncThreshold destFileSize
                 &&
               Transfer.Rsync.aboveRsyncThreshold srcFileSize ->
        Util.convertUnixErrorsToTransient
          "preprocessing file"
          (fun () ->
             let ifd = openFileIn fspathTo realPathTo fileKind in
             let bi =
               protect (fun () -> Transfer.Rsync.rsyncPreprocess ifd)
                 (fun () -> close_in_noerr ifd)
             in
             infd := Some ifd;
             (bi,
              (* Rsync decompressor *)
              fun ti ->
              let fd =
                destinationFd
                  fspathTo pathTo fileKind srcFileSize outfd in
              let eof =
                Transfer.Rsync.rsyncDecompress ifd fd showProgress ti
              in
              if eof then begin close_out fd; outfd := None end))
    | _ ->
        ([],
         (* Simple generic decompressor *)
         fun ti ->
         let fd = destinationFd fspathTo pathTo fileKind srcFileSize outfd in
         let eof = Transfer.receive fd showProgress ti in
         if eof then begin close_out fd; outfd := None end)
  in
  let file_id = Remote.newMsgId () in
  Lwt.catch
    (fun () ->
       decompressor := Remote.MsgIdMap.add file_id decompr !decompressor;
       Uutil.showProgress id Uutil.Filesize.zero "f";
       let (firstBi, remBi) =
         match bi with
           []               -> (None, [])
         | firstBi :: remBi -> (Some firstBi, remBi)
       in
       sendRemBi connFrom file_id remBi >>= fun () ->
       compressRemotely connFrom
         (firstBi, fspathFrom, pathFrom, fileKind, srcFileSize, id, file_id)
         >>= fun () ->
       decompressor :=
         Remote.MsgIdMap.remove file_id !decompressor; (* For GC *)
       close_all infd outfd;
       Lwt.return ())
    (fun e ->
       decompressor :=
         Remote.MsgIdMap.remove file_id !decompressor; (* For GC *)
       close_all_no_error infd outfd;
       Lwt.fail e)

(****)

let fileSize (fspath, path) =
  Util.convertUnixErrorsToTransient
    "getting file size"
    (fun () ->
       Lwt.return
        (Props.length (Fileinfo.get false fspath path).Fileinfo.desc))

let fileSizeOnHost =
  Remote.registerServerCmd  "fileSize" (fun _ -> fileSize)

(****)

let transferRessourceForkAndSetFileinfo
      connFrom fspathFrom pathFrom fspathTo pathTo realPathTo
      update desc fp ress id =
  (* Resource fork *)
  let ressLength = Osx.ressLength ress in
  begin if ressLength > Uutil.Filesize.zero then
    transferFileContents
      connFrom fspathFrom pathFrom fspathTo pathTo realPathTo update
      `RESS ressLength id
  else
    Lwt.return ()
  end >>= fun () ->
  setFileinfo fspathTo pathTo realPathTo update desc;
  Lwt.return ()

(* The ressOnly flag tells reallyTransferFile to skip transferring
   the data fork (which has already been taken care of by some external
   utility) and just transfer the resource fork (which external utilities
   are not necessarily good at). *)
let reallyTransferFile
      connFrom fspathFrom pathFrom fspathTo pathTo realPathTo
      update desc fp ress ressOnly id =
  debug (fun() -> Util.msg "reallyTransferFile(%s,%s) -> (%s,%s,%s,%s)%s\n"
      (Fspath.toDebugString fspathFrom) (Path.toString pathFrom)
      (Fspath.toDebugString fspathTo) (Path.toString pathTo)
      (Path.toString realPathTo) (Props.toString desc)
      (if ressOnly then " (ONLY RESOURCE FORK)" else ""));
  (if ressOnly then
    (* Skip data fork *)
    Lwt.return ()
  else begin
  removeOldTempFile fspathTo pathTo;
  (* Data fork *)
  transferFileContents
    connFrom fspathFrom pathFrom fspathTo pathTo realPathTo update
    `DATA (Props.length desc) id
  end) >>= fun () ->
  transferRessourceForkAndSetFileinfo
    connFrom fspathFrom pathFrom fspathTo pathTo realPathTo
    update desc fp ress id

(****)

let copyprog =
  Prefs.createString "copyprog" "rsync --inplace --compress"
    "!external program for copying large files"
    ("A string giving the name of an "
     ^ "external program that can be used to copy large files efficiently  "
     ^ "(plus command-line switches telling it to copy files in-place).  "
     ^ "The default setting invokes {\\tt rsync} with appropriate "
     ^ "options---most users should not need to change it.")

let copyprogrest =
  Prefs.createString "copyprogrest" "rsync --partial --inplace --compress"
    "!variant of copyprog for resuming partial transfers"
    ("A variant of {\\tt copyprog} that names an external program "
     ^ "that should be used to continue the transfer of a large file "
     ^ "that has already been partially transferred.  Typically, "
     ^ "{\\tt copyprogrest} will just be {\\tt copyprog} "
     ^ "with one extra option (e.g., {\\tt --partial}, for rsync).  "
     ^ "The default setting invokes {\\tt rsync} with appropriate "
     ^ "options---most users should not need to change it.")

let copythreshold =
  Prefs.createInt "copythreshold" (-1)
    "!use copyprog on files bigger than this (if >=0, in Kb)"
    ("A number indicating above what filesize (in kilobytes) Unison should "
     ^ "use the external "
     ^ "copying utility specified by {\\tt copyprog}. Specifying 0 will cause "
     ^ "{\\em all} copies to use the external program; "
     ^ "a negative number will prevent any files from using it.  "
     ^ "The default is -1.  "
     ^ "See \\sectionref{speeding}{Making Unison Faster on Large Files} "
     ^ "for more information.")

let copyquoterem =
  Prefs.createString "copyquoterem" "default"
    "!add quotes to remote file name for copyprog (true/false/default)"
    ("When set to {\\tt true}, this flag causes Unison to add an extra layer "
     ^ "of quotes to the remote path passed to the external copy program. "
     ^ "This is needed by rsync, for example, which internally uses an ssh "
     ^ "connection requiring an extra level of quoting for paths containing "
     ^ "spaces. When this flag is set to {\\tt default}, extra quotes are "
     ^ "added if the value of {\\tt copyprog} contains the string "
     ^ "{\\tt rsync}.")

let tryCopyMovedFileLocal connFrom
            (fspathTo, pathTo, realPathTo, update, desc, fp, ress, id) =
  Lwt.return (tryCopyMovedFile fspathTo pathTo realPathTo update desc fp ress id)
let tryCopyMovedFileOnRoot =
  Remote.registerRootCmdWithConnection "tryCopyMovedFile" tryCopyMovedFileLocal

let setFileinfoLocal connFrom (fspathTo, pathTo, desc) =
  Lwt.return (Fileinfo.set fspathTo pathTo (`Set Props.fileDefault) desc)
let setFileinfoOnRoot =
  Remote.registerRootCmdWithConnection "setFileinfo" setFileinfoLocal

let targetExists checkSize fspathTo pathTo =
  let info = Fileinfo.get false fspathTo pathTo in
  info.Fileinfo.typ = `FILE
  && (match checkSize with
        `MakeWriteableAndCheckNonempty ->
          let perms = Props.perms info.Fileinfo.desc in
          let perms' = perms lor 0o600 in
          Util.convertUnixErrorsToTransient
            "making target writable"
            (fun () -> Fs.chmod (Fspath.concat fspathTo pathTo) perms');
          Props.length info.Fileinfo.desc > Uutil.Filesize.zero
      | `CheckDataSize desc ->
             Props.length info.Fileinfo.desc = Props.length desc
      | `CheckSize (desc,ress) ->
             Props.length info.Fileinfo.desc = Props.length desc
          && Osx.ressLength info.Fileinfo.osX.Osx.ressInfo =
             Osx.ressLength ress)

let targetExistsLocal connFrom (checkSize, fspathTo, pathTo) =
  Lwt.return (targetExists checkSize fspathTo pathTo)
let targetExistsOnRoot =
  Remote.registerRootCmdWithConnection
    "targetExists" targetExistsLocal

let formatConnectionInfo root =
  match root with
    Common.Local, _ -> ""
  | Common.Remote h, _ ->
      (* Find the (unique) nonlocal root *)
      match
         Safelist.find (function Clroot.ConnectLocal _ -> false | _ -> true)
           (Safelist.map Clroot.parseRoot (Globals.rawRoots()))
      with
        Clroot.ConnectByShell (_,rawhost,uo,_,_) ->
            (match uo with None -> "" | Some u -> u ^ "@")
          ^ rawhost ^ ":"
          (* Note that we don't do anything with the port -- hopefully
             this will not affect many people.  If we did want to include it,
             we'd have to fiddle with the rsync parameters in a slightly
             deeper way. *)
      | Clroot.ConnectBySocket (h',_,_) ->
          h ^ ":"
      | Clroot.ConnectLocal _ -> assert false

let shouldUseExternalCopyprog update desc =
     Prefs.read copyprog <> ""
  && Prefs.read copythreshold >= 0
  && Props.length desc >= Uutil.Filesize.ofInt64 (Int64.of_int 1)
  && Props.length desc >=
       Uutil.Filesize.ofInt64
         (Int64.mul (Int64.of_int 1000)
            (Int64.of_int (Prefs.read copythreshold)))
  && update = `Copy

let transferFileUsingExternalCopyprog
             rootFrom pathFrom rootTo fspathTo pathTo realPathTo
             update desc fp ress id =
  tryCopyMovedFileOnRoot rootTo rootFrom
       (fspathTo, pathTo, realPathTo, update, desc, fp, ress, id)
    >>= (fun b ->
  if b then Lwt.return ()
  else begin
    Uutil.showProgress id Uutil.Filesize.zero "ext";
    targetExistsOnRoot
      rootTo rootFrom (`MakeWriteableAndCheckNonempty, fspathTo, pathTo) >>= (fun b ->
    let prog =
      if b
        then Prefs.read copyprogrest
        else Prefs.read copyprog in
    let extraquotes = Prefs.read copyquoterem = "true" 
                   || (  Prefs.read copyquoterem = "default"
                      && Util.findsubstring "rsync" prog <> None) in
    let addquotes root s =
      match root with
      | Common.Local, _ -> s
      | Common.Remote _, _ -> if extraquotes then Uutil.quotes s else s in
    let fromSpec =
        (formatConnectionInfo rootFrom)
      ^ (addquotes rootFrom
           (Fspath.toString (Fspath.concat (snd rootFrom) pathFrom))) in
    let toSpec =
        (formatConnectionInfo rootTo)
      ^ (addquotes rootTo
           (Fspath.toString (Fspath.concat fspathTo pathTo))) in
    let cmd = prog ^ " "
               ^ (Uutil.quotes fromSpec) ^ " "
               ^ (Uutil.quotes toSpec) in
    Trace.log (Printf.sprintf "%s\n" cmd);
    let _,log = External.runExternalProgram cmd in
    debug (fun() ->
             let l = Util.trimWhitespace log in
             Util.msg "transferFileUsingExternalCopyprog %s: returned...\n%s%s"
               (Path.toString pathFrom)
               l (if l="" then "" else "\n"));
    targetExistsOnRoot
      rootTo rootFrom (`CheckDataSize desc, fspathTo, pathTo)
        >>= (fun b ->
    if not b then
      raise (Util.Transient (Printf.sprintf
        "External copy program did not create target file (or bad length): %s"
            (Path.toString pathTo)));
    Uutil.showProgress id (Props.length desc) "ext";
    Lwt.return ()))
  end)

(****)

(* We limit the size of the output buffers to about 512 KB
   (we cannot go above the limit below plus 64) *)
let transferFileReg = Lwt_util.make_region 440

let bufferSize sz =
  min 64 ((truncate (Uutil.Filesize.toFloat sz) + 1023) / 1024)
    (* Token queue *)
    +
  8 (* Read buffer *)

let transferFileLocal connFrom
                      (fspathFrom, pathFrom, fspathTo, pathTo, realPathTo,
                       update, desc, fp, ress, ressOnly, id) =
  if (not ressOnly)
     && tryCopyMovedFile fspathTo pathTo realPathTo update desc fp ress id
  then Lwt.return ()
  else reallyTransferFile
         connFrom fspathFrom pathFrom fspathTo pathTo realPathTo
         update desc fp ress ressOnly id

let transferFileOnRoot =
  Remote.registerRootCmdWithConnection "transferFile" transferFileLocal

let transferFile
    rootFrom pathFrom rootTo fspathTo pathTo realPathTo
    update desc fp ress ressOnly id =
  let bufSz = bufferSize (max (Props.length desc) (Osx.ressLength ress)) in
  (* This must be on the client: any lock on the server side may result
     in a deadlock under windows *)
  Lwt_util.run_in_region transferFileReg bufSz (fun () ->
    Abort.check id;
    transferFileOnRoot rootTo rootFrom
      (snd rootFrom, pathFrom, fspathTo, pathTo, realPathTo,
       update, desc, fp, ress, ressOnly, id))

(****)

let file rootFrom pathFrom rootTo fspathTo pathTo realPathTo
         update desc fp ress id =
  debug (fun() -> Util.msg "copyRegFile(%s,%s) -> (%s,%s,%s,%s,%s)\n"
      (Common.root2string rootFrom) (Path.toString pathFrom)
      (Common.root2string rootTo) (Path.toString realPathTo)
      (Fspath.toDebugString fspathTo) (Path.toString pathTo)
      (Props.toString desc));
  let timer = Trace.startTimer "Transmitting file" in
  begin match rootFrom, rootTo with
    (Common.Local, fspathFrom), (Common.Local, realFspathTo) ->
      localFile
        fspathFrom pathFrom fspathTo pathTo realPathTo
        update desc (Osx.ressLength ress) (Some id);
      Lwt.return ()
  | _ ->
      (* Check whether we actually need to copy the file (or whether it
         already exists from some interrupted previous transfer) *)
      targetExistsOnRoot
        rootTo rootFrom (`CheckSize (desc,ress), fspathTo, pathTo) >>= (fun b ->
      if b then begin
        Trace.log (Printf.sprintf
          "%s/%s has already been transferred\n"
          (Fspath.toDebugString fspathTo) (Path.toString pathTo));
        (* Make sure the file information is right *)
        setFileinfoOnRoot rootTo rootFrom (fspathTo, pathTo, desc)
      (* Check whether we should use an external program to copy the
         file *)
      end else if shouldUseExternalCopyprog update desc then begin
        (* First use the external program to copy the data fork *)
        transferFileUsingExternalCopyprog
          rootFrom pathFrom rootTo fspathTo pathTo realPathTo
          update desc fp ress id >>= (fun () ->
        (* Now use the regular transport mechanism to copy the resource
           fork *)
        begin if (Osx.ressLength ress) > Uutil.Filesize.zero then begin
          transferFile
            rootFrom pathFrom rootTo fspathTo pathTo realPathTo
            update desc fp ress true id
        end else Lwt.return ()
        end >>= (fun() ->
        (* Finally, set the file info *)
        setFileinfoOnRoot rootTo rootFrom (fspathTo, pathTo, desc)))
      end else
        (* Just transfer the file in the usual way with Unison's
           built-in facilities *)
        transferFile 
         rootFrom pathFrom rootTo fspathTo pathTo realPathTo
          update desc fp ress false id
      ) end >>= (fun () ->
  Trace.showTimer timer;
  Lwt.return ())
