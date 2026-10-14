use pocket_codex_host_svc::acp::claude;

use super::*;

fn spec(profile: &str) -> AgentSpec {
    AgentSpec {
        profile_id: profile.into(),
        display_name: "Agent".into(),
        program: "agent".into(),
        args: vec!["acp".into()],
    }
}

fn custom(protocol: ApiProtocol, url: &str) -> ProfileInput {
    ProfileInput {
        claude_env: None,
        source: Source::Custom,
        protocol: Some(protocol),
        base_url: Some(url.into()),
        model: Some(" m1 ".into()),
    }
}

fn inherited() -> ProfileInput {
    ProfileInput {
        claude_env: None,
        source: Source::Inherited,
        protocol: None,
        base_url: None,
        model: None,
    }
}

fn change(input: &ProfileInput, key: KeyChange) -> Change {
    Change {
        input: input.clone(),
        key,
        runtime: RuntimeChange::Keep,
    }
}

fn save(
    root: &Path,
    name: &str,
    input: &ProfileInput,
    key: KeyChange,
    expected: Option<u64>,
    engine: Engine<'_>,
) -> Result<HostProfile> {
    save_in(root, name, &change(input, key), expected, engine)
}

fn key_files(root: &Path) -> Vec<String> {
    let mut files: Vec<String> = std::fs::read_dir(root.join("keys"))
        .map(|dir| {
            dir.flatten()
                .filter_map(|e| e.file_name().to_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    files.sort();
    files
}

fn stored_key(root: &Path, name: &str) -> Option<String> {
    resolve_in(root, name)
        .expect("resolve")
        .endpoint
        .and_then(|e| e.key)
        .map(|k| k.expose().to_string())
}

#[test]
fn an_unsaved_instance_inherits_its_agent_configuration() {
    let dir = tempfile::tempdir().expect("tempdir");
    let profile = get_in(dir.path(), "codex-a").expect("get");
    assert_eq!(profile, HostProfile::inherited());
    let resolved = resolve_in(dir.path(), "codex-a").expect("resolve");
    assert_eq!(resolved, Resolved::inherited());
    assert!(codex(&resolved, "codex-a").expect("launch").args.is_empty());
    assert!(acp(&resolved, &spec("claude"), "codex-a")
        .expect("acp")
        .is_none());
    assert!(!dir.path().join("profiles.lock").exists(), "a read creates nothing");

    // Once a record file exists, reads take the lock like writers do.
    save(dir.path(), "codex-a", &inherited(), KeyChange::Keep, None, Engine::Codex).expect("save");
    std::fs::remove_file(dir.path().join("profiles.lock")).expect("remove lock");
    get_in(dir.path(), "codex-a").expect("get");
    assert!(dir.path().join("profiles.lock").exists(), "a read of a record locks");
}

#[test]
fn a_custom_provider_round_trips_without_reading_the_key_back() {
    let dir = tempfile::tempdir().expect("tempdir");
    let saved = save(
        dir.path(),
        "codex-a",
        &custom(ApiProtocol::Responses, " https://gw.example.com/v1/ "),
        KeyChange::Replace(Secret::new(" sk-host ")),
        Some(0),
        Engine::Codex,
    )
    .expect("save");
    assert_eq!(saved.source, Source::Custom);
    assert_eq!(saved.base_url.as_deref(), Some("https://gw.example.com/v1"));
    assert_eq!(saved.model.as_deref(), Some("m1"));
    assert!(saved.key_set);
    assert_eq!(saved.revision, 1);
    assert!(saved.problem.is_none());
    assert!(!format!("{saved:?}").contains("sk-host"));
    let file = std::fs::read_to_string(profiles_path(dir.path())).expect("profiles");
    assert!(!file.contains("sk-host"), "the key is never in the profile file");

    let resolved = resolve_in(dir.path(), "codex-a").expect("resolve");
    let endpoint = resolved.endpoint.as_ref().expect("endpoint");
    assert_eq!(endpoint.key.as_ref().map(Secret::expose), Some("sk-host"));
    assert!(resolved.authority.is_some());
    let launch = codex(&resolved, "codex-a").expect("launch");
    assert!(!launch.args.join(" ").contains("sk-host"), "no key in argv");
    assert_eq!(launch.env.len(), 1);
    assert_eq!(launch.env[0].1.expose(), "sk-host");

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let mut files = vec![profiles_path(dir.path()), dir.path().join("profiles.lock")];
        files.extend(
            key_files(dir.path())
                .iter()
                .map(|f| files::key_path(dir.path(), f)),
        );
        for file in files {
            let mode = std::fs::metadata(file).expect("meta").permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        for dir in [dir.path().to_path_buf(), dir.path().join("keys")] {
            let mode = std::fs::metadata(dir).expect("meta").permissions().mode();
            assert_eq!(mode & 0o777, 0o700);
        }
    }
}

#[test]
fn keep_replace_and_remove_change_only_the_key() {
    let dir = tempfile::tempdir().expect("tempdir");
    let input = custom(ApiProtocol::Responses, "https://gw.example.com");
    let save = |key, expected| save(dir.path(), "oc", &input, key, expected, Engine::Codex);
    assert!(
        save(KeyChange::Replace(Secret::new("one")), None)
            .expect("1")
            .key_set
    );
    let first_files = key_files(dir.path());
    assert_eq!(first_files.len(), 1);
    assert!(save(KeyChange::Keep, Some(1)).expect("2").key_set);
    assert_eq!(key_files(dir.path()), first_files, "keep reuses the same file");
    assert_eq!(stored_key(dir.path(), "oc").as_deref(), Some("one"));
    save(KeyChange::Replace(Secret::new("two")), Some(2)).expect("3");
    assert_eq!(stored_key(dir.path(), "oc").as_deref(), Some("two"));
    let replaced = key_files(dir.path());
    assert_eq!(replaced.len(), 1, "the old key file is removed after the commit");
    assert_ne!(replaced, first_files, "a new generation");
    let removed = save(KeyChange::Remove, Some(3)).expect("4");
    assert!(!removed.key_set);
    assert_eq!(removed.revision, 4);
    assert!(key_files(dir.path()).is_empty());
    assert!(save(KeyChange::Replace(Secret::new("  ")), Some(4)).is_err());
    assert_eq!(get_in(dir.path(), "oc").expect("get").revision, 4);
}

#[test]
fn a_failed_commit_keeps_the_old_record_and_its_key() {
    let dir = tempfile::tempdir().expect("tempdir");
    let input = custom(ApiProtocol::Responses, "https://a.example.com");
    save(dir.path(), "c", &input, KeyChange::Replace(Secret::new("old")), None, Engine::Codex)
        .expect("1");
    let before = key_files(dir.path());
    files::fail_commit_once();
    let failed = save(
        dir.path(),
        "c",
        &custom(ApiProtocol::Responses, "https://b.example.com"),
        KeyChange::Replace(Secret::new("new")),
        Some(1),
        Engine::Codex,
    );
    assert!(failed.is_err());
    // The record, its revision and the key it names are all the old ones;
    // the new key file was never left behind.
    let kept = get_in(dir.path(), "c").expect("get");
    assert_eq!(kept.revision, 1);
    assert_eq!(kept.base_url.as_deref(), Some("https://a.example.com"));
    assert_eq!(stored_key(dir.path(), "c").as_deref(), Some("old"));
    assert_eq!(key_files(dir.path()), before);
}

#[test]
fn a_staged_save_rolls_back_to_the_exact_previous_record() {
    let dir = tempfile::tempdir().expect("tempdir");
    let input = custom(ApiProtocol::Responses, "https://a.example.com");
    save(dir.path(), "c", &input, KeyChange::Replace(Secret::new("old")), None, Engine::Codex)
        .expect("1");
    let previous = resolve_in(dir.path(), "c").expect("previous");
    let (staged_profile, staged) =
        stage_in(dir.path(), "c", &change(&inherited(), KeyChange::Keep), Some(1), Engine::Codex)
            .expect("stage");
    assert_eq!(staged_profile.source, Source::Inherited);
    assert_eq!(key_files(dir.path()).len(), 1, "the old key survives staging");
    staged.rollback().expect("rollback");
    let restored = resolve_in(dir.path(), "c").expect("restored");
    assert_eq!(restored.revision, 3, "a newer revision, so stale editors reload");
    assert_eq!(restored.endpoint, previous.endpoint);
    assert_eq!(restored.authority, previous.authority, "the same service");

    // A save that came in meanwhile is never undone.
    let (_, staged) =
        stage_in(dir.path(), "c", &change(&inherited(), KeyChange::Keep), Some(3), Engine::Codex)
            .expect("stage");
    save(dir.path(), "c", &input, KeyChange::Replace(Secret::new("other")), Some(4), Engine::Codex)
        .expect("meanwhile");
    staged.rollback().expect("rollback");
    assert_eq!(get_in(dir.path(), "c").expect("get").revision, 5);
    assert_eq!(stored_key(dir.path(), "c").as_deref(), Some("other"));
}

fn stage_key(root: &Path, key: &str, expected: u64) -> Staged {
    let input = custom(ApiProtocol::Responses, "https://a.example.com");
    stage_in(
        root,
        "c",
        &change(&input, KeyChange::Replace(Secret::new(key))),
        Some(expected),
        Engine::Codex,
    )
    .expect("stage")
    .1
}

#[test]
fn interleaved_stages_never_remove_a_key_a_rollback_restores() {
    let dir = tempfile::tempdir().expect("tempdir");
    let input = custom(ApiProtocol::Responses, "https://a.example.com");
    save(dir.path(), "c", &input, KeyChange::Replace(Secret::new("k0")), None, Engine::Codex)
        .expect("K0");
    // A: K0 -> K1, B: K1 -> K2, then A finishes before B rolls back.
    let a = stage_key(dir.path(), "k1", 1);
    let b = stage_key(dir.path(), "k2", 2);
    a.finish();
    assert_eq!(stored_key(dir.path(), "c").as_deref(), Some("k2"));
    assert_eq!(key_files(dir.path()).len(), 2, "K1 stays pinned by B; K0 is gone");
    b.rollback().expect("B rolls back");
    let restored = get_in(dir.path(), "c").expect("get");
    assert!(restored.problem.is_none(), "{:?}", restored.problem);
    assert_eq!(restored.revision, 4);
    assert_eq!(stored_key(dir.path(), "c").as_deref(), Some("k1"), "B's previous key");
    assert_eq!(key_files(dir.path()).len(), 1, "only K1 is left");

    // The same holds when A rolls back after being superseded.
    let a = stage_key(dir.path(), "k3", 4);
    let b = stage_key(dir.path(), "k4", 5);
    a.rollback().expect("superseded rollback changes no record");
    b.rollback().expect("B rolls back");
    assert_eq!(stored_key(dir.path(), "c").as_deref(), Some("k3"));
}

#[test]
fn a_record_renamed_into_place_counts_as_committed() {
    let dir = tempfile::tempdir().expect("tempdir");
    let input = custom(ApiProtocol::Responses, "https://a.example.com");
    save(dir.path(), "c", &input, KeyChange::Replace(Secret::new("old")), None, Engine::Codex)
        .expect("1");
    files::fail_dir_sync_once(files::SyncFault::Record);
    let saved = save(
        dir.path(),
        "c",
        &input,
        KeyChange::Replace(Secret::new("new")),
        Some(1),
        Engine::Codex,
    )
    .expect("committed although the directory sync failed");
    assert_eq!(saved.revision, 2);
    assert!(get_in(dir.path(), "c").expect("get").problem.is_none());
    assert_eq!(stored_key(dir.path(), "c").as_deref(), Some("new"), "its key was kept");
}

/// Rewrite every pin's timestamp, as a large clock jump (or a day passing)
/// would make it look.
fn age_pins(root: &Path, at: u64) {
    let path = profiles_path(root);
    let mut raw: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&path).expect("read")).expect("json");
    let pins = raw["pins"].as_object_mut().expect("pins");
    assert!(!pins.is_empty(), "the stages are pinned");
    for pin in pins.values_mut() {
        pin["at"] = at.into();
    }
    std::fs::write(&path, serde_json::to_vec(&raw).expect("encode")).expect("write");
}

#[test]
fn a_live_pin_never_ages_out_across_a_clock_jump() {
    let dir = tempfile::tempdir().expect("tempdir");
    let input = custom(ApiProtocol::Responses, "https://a.example.com");
    save(dir.path(), "c", &input, KeyChange::Replace(Secret::new("k0")), None, Engine::Codex)
        .expect("K0");
    // A: K0 -> K1, B: K1 -> K2, both live while the clock jumps forward.
    let a = stage_key(dir.path(), "k1", 1);
    let b = stage_key(dir.path(), "k2", 2);
    age_pins(dir.path(), 0);
    // A save of another instance meanwhile must not drop their (seemingly
    // ancient) pins.
    save(dir.path(), "d", &input, KeyChange::Replace(Secret::new("kd")), None, Engine::Codex)
        .expect("D");
    a.finish();
    assert_eq!(key_files(dir.path()).len(), 3, "K1 (B's pin), K2 and D's key remain");
    b.rollback().expect("B rolls back");
    let restored = get_in(dir.path(), "c").expect("get");
    assert!(restored.problem.is_none(), "{:?}", restored.problem);
    assert_eq!(stored_key(dir.path(), "c").as_deref(), Some("k1"), "B's previous key");
}

#[test]
fn a_read_that_found_no_record_file_answers_that_snapshot() {
    let dir = tempfile::tempdir().expect("tempdir");
    // Another process commits a record and its key between this read's
    // check and its read (and could replace and sweep that key next).
    files::on_absent_check(|root| {
        let key = files::key_file_name("c", Some(&uuid::Uuid::new_v4().to_string()));
        std::fs::create_dir_all(root.join("keys")).expect("keys");
        std::fs::write(files::key_path(root, &key), b"k-other").expect("key");
        let record = serde_json::json!({
            "version": FILE_VERSION,
            "hosts": { "c": {
                "source": "custom", "protocol": "responses",
                "base_url": "https://other.example.com", "key": key, "revision": 1,
            } },
        });
        std::fs::write(profiles_path(root), record.to_string()).expect("record");
    });
    assert_eq!(resolve_in(dir.path(), "c").expect("resolve"), Resolved::inherited());
    // The next read locks and sees the committed record.
    assert_eq!(stored_key(dir.path(), "c").as_deref(), Some("k-other"));
    assert_eq!(get_in(dir.path(), "c").expect("get").revision, 1);
}

#[test]
fn a_key_that_cannot_be_made_durable_fails_its_save() {
    let dir = tempfile::tempdir().expect("tempdir");
    let input = custom(ApiProtocol::Responses, "https://a.example.com");
    save(dir.path(), "c", &input, KeyChange::Replace(Secret::new("old")), None, Engine::Codex)
        .expect("1");
    let before = key_files(dir.path());
    files::fail_dir_sync_once(files::SyncFault::Key);
    let refused = save(
        dir.path(),
        "c",
        &input,
        KeyChange::Replace(Secret::new("new")),
        Some(1),
        Engine::Codex,
    );
    assert!(refused.is_err(), "no record may name a key a crash could lose");
    assert_eq!(get_in(dir.path(), "c").expect("get").revision, 1);
    assert_eq!(stored_key(dir.path(), "c").as_deref(), Some("old"));
    assert_eq!(key_files(dir.path()), before, "the new key file is gone");
}

#[test]
fn an_uncertain_record_write_removes_no_key() {
    let dir = tempfile::tempdir().expect("tempdir");
    let input = custom(ApiProtocol::Responses, "https://a.example.com");
    save(dir.path(), "c", &input, KeyChange::Replace(Secret::new("k0")), None, Engine::Codex)
        .expect("K0");
    let staged = stage_key(dir.path(), "k1", 1);
    // The record write of the finish may not survive a crash, which would
    // bring back the record naming K0: K0 stays.
    files::fail_dir_sync_once(files::SyncFault::Record);
    staged.finish();
    assert_eq!(key_files(dir.path()).len(), 2, "K0 kept");
    assert_eq!(stored_key(dir.path(), "c").as_deref(), Some("k1"));
    // A later durable save cleans it up.
    save(dir.path(), "c", &input, KeyChange::Keep, Some(2), Engine::Codex).expect("durable");
    assert_eq!(key_files(dir.path()).len(), 1, "only K1 is left");
}

#[test]
fn cleanup_never_runs_without_the_lock_and_an_authoritative_read() {
    let dir = tempfile::tempdir().expect("tempdir");
    let input = custom(ApiProtocol::Responses, "https://a.example.com");
    save(dir.path(), "c", &input, KeyChange::Replace(Secret::new("k0")), None, Engine::Codex)
        .expect("K0");
    let staged = stage_key(dir.path(), "k1", 1);
    let committed = std::fs::read(profiles_path(dir.path())).expect("read");
    std::fs::write(profiles_path(dir.path()), b"{ unreadable").expect("corrupt");
    staged.finish();
    assert_eq!(key_files(dir.path()).len(), 2, "an unreadable file removes no key");
    std::fs::write(profiles_path(dir.path()), &committed).expect("restore");

    #[cfg(unix)]
    {
        // A lock that cannot be taken removes nothing either.
        let staged = stage_key(dir.path(), "k2", 2);
        let lock = dir.path().join("profiles.lock");
        std::fs::remove_file(&lock).expect("remove lock");
        std::fs::create_dir(&lock).expect("block the lock");
        staged.finish();
        assert_eq!(key_files(dir.path()).len(), 3, "no lock, no cleanup");
        std::fs::remove_dir(&lock).expect("unblock");
    }
    save(dir.path(), "c", &input, KeyChange::Keep, None, Engine::Codex).expect("next save");
    assert!(stored_key(dir.path(), "c").is_some());
}

#[test]
fn a_stage_resolves_what_it_committed_not_a_later_save() {
    let dir = tempfile::tempdir().expect("tempdir");
    let staged = stage_in(
        dir.path(),
        "c",
        &change(
            &custom(ApiProtocol::Responses, "https://a.example.com"),
            KeyChange::Replace(Secret::new("ka")),
        ),
        Some(0),
        Engine::Codex,
    )
    .expect("stage")
    .1;
    save(
        dir.path(),
        "c",
        &custom(ApiProtocol::Responses, "https://b.example.com"),
        KeyChange::Replace(Secret::new("kb")),
        Some(1),
        Engine::Codex,
    )
    .expect("a save meanwhile");
    let resolved = staged.resolved().expect("resolved").clone();
    staged.finish();
    let endpoint = resolved.endpoint.expect("endpoint");
    assert_eq!(endpoint.base_url, "https://a.example.com");
    assert_eq!(endpoint.key.as_ref().map(Secret::expose), Some("ka"));
    assert_eq!(resolved.revision, 1);
}

#[test]
fn a_key_must_be_one_printable_token() {
    let dir = tempfile::tempdir().expect("tempdir");
    let input = custom(ApiProtocol::Responses, "https://a.example.com");
    for bad in ["sk-a\nsk-b", "sk a", "sk\t1", "sk\"1", "sk\\n1", "sk-é"] {
        save(dir.path(), "c", &input, KeyChange::Replace(Secret::new(bad)), None, Engine::Codex)
            .expect_err("refused");
    }
    assert_eq!(get_in(dir.path(), "c").expect("get").revision, 0);
    assert!(key_files(dir.path()).is_empty());
}

#[test]
fn a_save_made_elsewhere_is_not_overwritten() {
    let dir = tempfile::tempdir().expect("tempdir");
    let input = custom(ApiProtocol::Responses, "https://a.example.com");
    save(dir.path(), "codex-a", &input, KeyChange::Keep, Some(0), Engine::Codex).expect("1");
    let stale = save(dir.path(), "codex-a", &inherited(), KeyChange::Keep, Some(0), Engine::Codex)
        .expect_err("stale");
    assert!(stale.to_string().contains("changed elsewhere"));
    let kept = get_in(dir.path(), "codex-a").expect("get");
    assert_eq!(kept.source, Source::Custom);
    assert_eq!(kept.revision, 1);
}

#[test]
fn only_real_mappings_are_accepted() {
    let dir = tempfile::tempdir().expect("tempdir");
    let url = "https://gw.example.com/v1";
    let refused = |name: &str, input: ProfileInput, engine: Engine<'_>| {
        save(dir.path(), name, &input, KeyChange::Keep, None, engine).expect_err(name);
        assert_eq!(get_in(dir.path(), name).expect("get").revision, 0, "{name} unsaved");
    };
    refused("c1", custom(ApiProtocol::AnthropicMessages, url), Engine::Codex);
    refused("c2", custom(ApiProtocol::ChatCompletions, url), Engine::Codex);
    let claude_spec = spec(claude::PROFILE_ID);
    refused("cl1", custom(ApiProtocol::Responses, url), Engine::Acp(&claude_spec));
    refused("cl2", custom(ApiProtocol::ChatCompletions, url), Engine::Acp(&claude_spec));
    let generic = spec("custom-x-1234");
    for protocol in ApiProtocol::ALL {
        refused("g", custom(protocol, url), Engine::Acp(&generic));
    }
    let official = ProfileInput {
        claude_env: None,
        source: Source::Official,
        ..inherited()
    };
    refused("oc", official.clone(), Engine::OpenCode);
    for protocol in ApiProtocol::ALL {
        let profile = save(
            dir.path(),
            "oc-custom",
            &custom(protocol, url),
            KeyChange::Replace(Secret::new("native-key")),
            None,
            Engine::OpenCode,
        )
        .expect("native OpenCode supports each custom API");
        assert_eq!(profile.protocol, Some(protocol));
    }
    let mut no_api = custom(ApiProtocol::Responses, url);
    no_api.protocol = None;
    refused("c3", no_api, Engine::Codex);
    refused("c4", custom(ApiProtocol::Responses, "ftp://gw.example.com"), Engine::Codex);
    refused("c5", custom(ApiProtocol::Responses, "https://u:p@gw.example.com"), Engine::Codex);
    let mut no_url = custom(ApiProtocol::Responses, url);
    no_url.base_url = None;
    refused("c6", no_url, Engine::Codex);
    let mut control = custom(ApiProtocol::Responses, url);
    control.model = Some("m\n1".into());
    refused("c7", control, Engine::Codex);
    // A key belongs to a custom provider only.
    save(dir.path(), "c8", &inherited(), KeyChange::Replace(Secret::new("k")), None, Engine::Codex)
        .expect_err("no key for inherited");

    for engine in [Engine::Codex, Engine::Acp(&generic), Engine::OpenCode] {
        save(dir.path(), "inherit", &inherited(), KeyChange::Keep, None, engine).expect("ok");
    }
    let saved = save(dir.path(), "codex-o", &official, KeyChange::Keep, None, Engine::Codex)
        .expect("official");
    assert_eq!(saved.source, Source::Official);
    let resolved = resolve_in(dir.path(), "codex-o").expect("resolve");
    let args = codex(&resolved, "codex-o").expect("launch").args.join(" ");
    assert!(args.contains("model_provider=\"openai\""));
    assert!(args.contains("openai_base_url=\"\""), "the official endpoint is not rerouted");
    save(
        dir.path(),
        "claude-a",
        &custom(ApiProtocol::AnthropicMessages, url),
        KeyChange::Replace(Secret::new("k")),
        None,
        Engine::Acp(&claude_spec),
    )
    .expect("claude messages");
}

#[test]
fn leaving_the_custom_provider_forgets_its_key_and_fields() {
    let dir = tempfile::tempdir().expect("tempdir");
    let input = custom(ApiProtocol::Responses, "https://gw.example.com");
    save(dir.path(), "c", &input, KeyChange::Replace(Secret::new("k")), None, Engine::Codex)
        .expect("1");
    let official = ProfileInput {
        claude_env: None,
        source: Source::Official,
        ..input
    };
    let saved = save(dir.path(), "c", &official, KeyChange::Keep, Some(1), Engine::Codex)
        .expect("official");
    assert!(!saved.key_set);
    assert!(saved.base_url.is_none() && saved.model.is_none());
    assert!(key_files(dir.path()).is_empty());
}

#[test]
fn the_authority_moves_with_the_service_and_its_key_only() {
    let dir = tempfile::tempdir().expect("tempdir");
    let claude = spec("claude");
    let input = custom(ApiProtocol::AnthropicMessages, "https://gw.example.com/v1");
    // The argument only labels which save is being looked at.
    let authority = |_after_save: u64| resolve_in(dir.path(), "oc").expect("resolve").authority;
    save(
        dir.path(),
        "oc",
        &input,
        KeyChange::Replace(Secret::new("sk-1")),
        None,
        Engine::Acp(&claude),
    )
    .expect("1");
    let first = authority(1).expect("custom has an authority");
    // A runtime-only save keeps it.
    let runtime = Change {
        input: input.clone(),
        key: KeyChange::Keep,
        runtime: RuntimeChange::Set(Runtime::Acp(claude.clone())),
    };
    save_in(dir.path(), "oc", &runtime, Some(1), Engine::Acp(&claude)).expect("2");
    assert_eq!(authority(2).as_deref(), Some(first.as_str()));
    // A replaced key is another account: a new authority.
    save(
        dir.path(),
        "oc",
        &input,
        KeyChange::Replace(Secret::new("sk-2")),
        Some(2),
        Engine::Acp(&claude),
    )
    .expect("3");
    let second = authority(3).expect("authority");
    assert_ne!(second, first);
    // So does another URL.
    let moved = custom(ApiProtocol::AnthropicMessages, "https://other.example.com/v1");
    save(dir.path(), "oc", &moved, KeyChange::Keep, Some(3), Engine::Acp(&claude)).expect("4");
    assert_ne!(authority(4).as_deref(), Some(second.as_str()));
    // Inherited has none.
    save(dir.path(), "oc", &inherited(), KeyChange::Keep, Some(4), Engine::Acp(&claude))
        .expect("5");
    assert!(authority(5).is_none());

    let resolved = {
        save(
            dir.path(),
            "oc",
            &input,
            KeyChange::Replace(Secret::new("sk-oc")),
            Some(5),
            Engine::Acp(&claude),
        )
        .expect("6");
        resolve_in(dir.path(), "oc").expect("resolve")
    };
    let (launch, keyed) = acp(&resolved, &claude, "oc").expect("acp").expect("custom");
    assert!(launch.session_meta.is_some());
    assert!(!keyed.contains("sk-oc"), "the authority is opaque");
}

#[test]
fn a_runtime_is_saved_validated_and_kind_checked() {
    let dir = tempfile::tempdir().expect("tempdir");
    let codex_runtime = Runtime::Codex {
        binary: Some(" /opt/codex ".into()),
        port: 4500,
        proxy: Some(" http://127.0.0.1:7890 ".into()),
    };
    let saved = save_in(
        dir.path(),
        "c",
        &Change {
            input: inherited(),
            key: KeyChange::Keep,
            runtime: RuntimeChange::Set(codex_runtime),
        },
        Some(0),
        Engine::Codex,
    )
    .expect("runtime");
    assert_eq!(
        saved.runtime,
        Some(Runtime::Codex {
            binary: Some("/opt/codex".into()),
            port: 4500,
            proxy: Some("http://127.0.0.1:7890".into()),
        })
    );
    let resolved = resolve_in(dir.path(), "c").expect("resolve");
    assert_eq!(resolved.runtime, saved.runtime, "one revision for both");
    // A provider-only save keeps it; a clear forgets it.
    save(dir.path(), "c", &inherited(), KeyChange::Keep, Some(1), Engine::Codex).expect("2");
    assert!(get_in(dir.path(), "c").expect("get").runtime.is_some());
    let cleared = save_in(
        dir.path(),
        "c",
        &Change {
            input: inherited(),
            key: KeyChange::Keep,
            runtime: RuntimeChange::Clear,
        },
        Some(2),
        Engine::Codex,
    )
    .expect("clear");
    assert!(cleared.runtime.is_none());

    let refuse = |runtime: Runtime, engine: Engine<'_>| {
        let change = Change {
            input: inherited(),
            key: KeyChange::Keep,
            runtime: RuntimeChange::Set(runtime),
        };
        save_in(dir.path(), "r", &change, None, engine).expect_err("refused");
    };
    let agent = spec("claude");
    refuse(Runtime::Acp(agent.clone()), Engine::Codex);
    refuse(
        Runtime::Codex {
            binary: None,
            port: 1,
            proxy: Some("not a proxy".into()),
        },
        Engine::Codex,
    );
    refuse(Runtime::Acp(spec("custom-x-1")), Engine::Acp(&agent));
    let empty = AgentSpec {
        program: String::new(),
        ..agent.clone()
    };
    refuse(Runtime::Acp(empty.clone()), Engine::Acp(&empty));
    assert_eq!(get_in(dir.path(), "r").expect("get").revision, 0);
}

#[test]
fn malformed_records_are_reported_never_resolved_to_another_provider() {
    let dir = tempfile::tempdir().expect("tempdir");
    let write = |record: serde_json::Value| {
        let file = serde_json::json!({ "version": 2, "hosts": { "h": record } });
        std::fs::create_dir_all(dir.path()).expect("dir");
        std::fs::write(profiles_path(dir.path()), file.to_string()).expect("write");
    };
    for record in [
        serde_json::json!({ "source": "mystery", "revision": 1 }),
        serde_json::json!({ "source": "custom", "protocol": "smoke", "baseUrl": "https://a", "revision": 1 }),
        serde_json::json!({ "source": "custom", "protocol": "responses", "base_url": "ftp://a", "revision": 1 }),
        serde_json::json!({ "source": "custom", "protocol": "responses", "revision": 1 }),
        serde_json::json!({ "source": "inherited", "revision": 0 }),
        serde_json::json!({ "source": "custom", "protocol": "responses", "base_url": "https://a.example.com", "key": "../../escape", "revision": 1 }),
        serde_json::json!({ "source": "custom", "protocol": "responses", "base_url": "https://a.example.com", "key": "68.00000000-0000-0000-0000-000000000000.key", "revision": 1 }),
    ] {
        write(record.clone());
        let resolved = resolve_in(dir.path(), "h");
        assert!(resolved.is_err(), "{record} must not resolve");
        let profile = get_in(dir.path(), "h").expect("still listed");
        assert!(profile.problem.is_some(), "{record} reports a problem");
        assert_eq!(profile.source, Source::Inherited, "shown, never used");
    }
    // Saving over a broken record replaces it.
    let revision = get_in(dir.path(), "h").expect("get").revision;
    save(dir.path(), "h", &inherited(), KeyChange::Keep, Some(revision), Engine::Codex)
        .expect("replace");
    assert!(resolve_in(dir.path(), "h").is_ok());
}

#[test]
fn a_version_one_store_is_still_read() {
    let dir = tempfile::tempdir().expect("tempdir");
    std::fs::create_dir_all(dir.path().join("keys")).expect("dir");
    let legacy = files::key_file_name("h", None);
    std::fs::write(files::key_path(dir.path(), &legacy), "sk-legacy").expect("key");
    let file = serde_json::json!({ "version": 1, "hosts": { "h": {
        "source": "custom", "protocol": "responses",
        "base_url": "https://gw.example.com", "revision": 3
    } } });
    std::fs::write(profiles_path(dir.path()), file.to_string()).expect("write");
    let resolved = resolve_in(dir.path(), "h").expect("resolve");
    assert_eq!(resolved.revision, 3);
    assert_eq!(stored_key(dir.path(), "h").as_deref(), Some("sk-legacy"));
    assert!(resolved.authority.is_some());
    // The next save moves it to version 2 with a generation key.
    let input = custom(ApiProtocol::Responses, "https://gw.example.com");
    save(
        dir.path(),
        "h",
        &input,
        KeyChange::Replace(Secret::new("sk-new")),
        Some(3),
        Engine::Codex,
    )
    .expect("save");
    assert!(!key_files(dir.path()).contains(&legacy), "the legacy key is gone");
    let raw = std::fs::read_to_string(profiles_path(dir.path())).expect("read");
    assert!(raw.contains("\"version\": 2"));
}

#[test]
fn an_unreadable_file_is_reported_and_left_alone() {
    let dir = tempfile::tempdir().expect("tempdir");
    std::fs::create_dir_all(dir.path()).expect("dir");
    std::fs::write(profiles_path(dir.path()), b"{ secret-looking garbage").expect("write");
    let err = get_in(dir.path(), "codex-a").expect_err("unreadable");
    assert!(!err.to_string().contains("garbage"), "the content is not quoted");
    save(dir.path(), "codex-a", &inherited(), KeyChange::Keep, None, Engine::Codex)
        .expect_err("not overwritten");
    let raw = std::fs::read(profiles_path(dir.path())).expect("read");
    assert_eq!(raw, b"{ secret-looking garbage");
}

#[test]
fn names_are_keyed_as_hosts_are_named() {
    let dir = tempfile::tempdir().expect("tempdir");
    let input = custom(ApiProtocol::Responses, "https://gw.example.com");
    save(dir.path(), "My Host", &input, KeyChange::Keep, None, Engine::Codex).expect("save");
    let same = get_in(dir.path(), "my-host").expect("get");
    assert_eq!(same.revision, 1);
    assert!(get_in(dir.path(), "   ").is_err(), "a blank name is not the default host");
}

#[test]
fn redaction_withholds_lines_with_the_key_and_bounds_the_text() {
    let mut resolved = Resolved::inherited();
    resolved.source = Source::Custom;
    resolved.endpoint = Some(ProviderEndpoint {
        protocol: ApiProtocol::Responses,
        base_url: "https://gw.example.com".into(),
        key: Some(Secret::new("sk-secret")),
        model: None,
    });
    let shown = redact("bind failed\nauth: Bearer sk-secret\nretry", &resolved);
    assert!(!shown.contains("sk-secret"));
    assert!(shown.contains("bind failed") && shown.contains("retry"));
    assert!(redact(&"é".repeat(2000), &resolved).chars().count() <= 601);
}

#[test]
fn redaction_finds_encoded_escaped_and_wrapped_copies() {
    let key = "sk-dummy/AB+cd=0123";
    let redactor = Redactor::new(Some(&Secret::new(key)));
    for leaked in [
        format!("token={key}"),
        "url?key=sk-dummy%2FAB%2Bcd%3D0123".to_string(),
        "url?key=sk-dummy%2fAB%2bcd%3d0123".to_string(),
        r#"{"key":"sk-dummy\/AB+cd=0123"}"#.to_string(),
    ] {
        assert_eq!(redactor.line(&leaked), "[line withheld: it held the key]", "{leaked}");
    }
    // A copy wrapped across two lines withholds both halves.
    let wrapped = "header: Bearer sk-dummy/A\nB+cd=0123 accepted\nnext";
    let shown = redactor.text(wrapped);
    assert!(!shown.contains("sk-dummy/A") && !shown.contains("B+cd=0123"), "{shown}");
    assert!(shown.ends_with("next"));
    assert_eq!(redactor.line("unrelated output"), "unrelated output");
    assert_eq!(Redactor::new(None).text("a\nb"), "a\nb");
    // An accepted short dummy key split into pieces under eight characters.
    let short = Redactor::new(Some(&Secret::new("sk-ABC0123")));
    let withheld = "[line withheld: it held the key]";
    assert_eq!(short.text("x sk-AB\nC0123 y"), format!("{withheld}\n{withheld}"));
}
