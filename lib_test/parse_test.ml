(*
 * Copyright (C) 2011-2013 Citrix Inc
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
open OUnit
open Tar_lwt_unix
open Lwt

exception Cstruct_differ

let cstruct_equal a b =
  let check_contents a b =
    try
      for i = 0 to Cstruct.len a - 1 do
        let a' = Cstruct.get_char a i in
        let b' = Cstruct.get_char b i in
        if a' <> b' then raise Cstruct_differ
      done;
      true
    with _ -> false in
  (Cstruct.len a = (Cstruct.len b)) && (check_contents a b)

let header () =
  (* check header marshalling and unmarshalling *)
  let h = Header.make ~file_mode:5 ~user_id:1001 ~group_id:1002 ~mod_time:55L ~link_name:"" "hello" 1234L in
  let txt = "hello\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\0000000005\0000001751\0000001752\00000000002322\00000000000067\0000005534\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000" in
  let c = Cstruct.create (String.length txt) in
  Cstruct.blit_from_string txt 0 c 0 (String.length txt);
  let c' = Cstruct.create Header.length in
  Header.marshal c' h;
  assert_equal ~cmp:cstruct_equal c c';
  let printer = function
    | None -> "None"
    | Some x -> "Some " ^ (Header.to_detailed_string x) in
  assert_equal ~printer (Some h) (Header.unmarshal c');
  assert_equal ~printer:string_of_int 302 (Header.compute_zero_padding_length h)

let set_difference a b = List.filter (fun a -> not(List.mem a b)) a

let finally f g = try let results = f () in g (); results with e -> g (); raise e

let with_tar f =
  let files = List.map (fun x -> "lib/" ^ x) (Array.to_list (Sys.readdir "lib")) in
  let tar_filename = Filename.temp_file "tar-test" ".tar" in
  let cmdline = Printf.sprintf "tar -cf %s %s" tar_filename (String.concat " " files) in
  begin match Unix.system cmdline with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED n -> failwith (Printf.sprintf "%s: exited with %d" cmdline n)
  | _ -> failwith (Printf.sprintf "%s: unknown error" cmdline)
  end;
  finally (fun () -> f tar_filename files) (fun () -> Unix.unlink tar_filename)

let can_read_tar () =
  with_tar
    (fun tar_filename files ->
      let fd = Unix.openfile tar_filename [ Unix.O_RDONLY ] 0 in
      let files' = List.map (fun t -> t.Tar_unix.Header.file_name) (Tar_unix.Archive.list fd) in
      Unix.close fd;
      let missing = set_difference files files' in
      let missing' = set_difference files' files in
      assert_equal ~printer:(String.concat "; ") [] missing;
      assert_equal ~printer:(String.concat "; ") [] missing'
    )

let expect_ok = function
  | `Ok x -> x
  | `Error _ -> failwith "expect_ok: got Error"

let can_read_through_BLOCK () =
  with_tar
    (fun tar_filename files ->
      let t =
Printf.fprintf stderr "%s\n%!" tar_filename;
        Block.connect tar_filename
        >>= fun r ->
        let b = expect_ok r in
        let module KV_RO = Tar_mirage.Make_KV_RO(Block) in
        KV_RO.connect b
        >>= fun r ->
        let k = expect_ok r in
        Lwt_list.iter_s
          (fun file ->
Printf.fprintf stderr "%s\n%!" file;
            KV_RO.size k file
            >>= fun r ->
            let size = expect_ok r in
            let stats = Unix.LargeFile.stat file in
            assert_equal ~printer:Int64.to_string stats.Unix.LargeFile.st_size size;
            return ()
          ) files in
      Lwt_main.run t
    )
        
let _ =
  let verbose = ref false in
  Arg.parse [
    "-verbose", Arg.Unit (fun _ -> verbose := true), "Run in verbose mode";
  ] (fun x -> Printf.fprintf stderr "Ignoring argument: %s" x)
    "Test tar parser";

  let suite = "tar" >:::
    [
      "header" >:: header;
      "can_read_tar" >:: can_read_tar;
      "can_read_through_BLOCK" >:: can_read_through_BLOCK;
     ] in
  run_test_tt ~verbose:!verbose suite

