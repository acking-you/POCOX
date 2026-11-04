//! Forking through the host's gateway: what it offers and what its answers
//! mean.

use super::*;
use crate::engine::app_session::ForkOutcome;

#[test]
fn fork_is_offered_as_the_host_verified_it() {
    let info = |fork: Value| json!({"phase": {"state": "ready"}, "capabilities": {"fork": true}, "fork": fork});
    let caps = capabilities_of(&info(json!({"supported": true, "throughTurn": true})), 1);
    assert!(caps.fork && caps.fork_through_turn && caps.fork_busy_source);
    let caps = capabilities_of(&info(json!({"supported": true, "throughTurn": false})), 1);
    assert!(caps.fork && !caps.fork_through_turn);
    // An agent's own advertisement is not the host's verification, and an
    // older host says nothing.
    for fork in [json!({"supported": false, "throughTurn": false}), Value::Null] {
        let caps = capabilities_of(&info(fork), 1);
        assert!(!caps.fork && !caps.fork_through_turn && !caps.fork_busy_source);
    }
}

#[test]
fn a_fork_separates_a_refusal_from_a_lost_answer() {
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("init");
    let gateway = runtime::runtime().block_on(fake_gateway(snapshot(json!([]), json!([]))));
    let own = Context::of(&transport(None, "relay:fork"));
    let key = key_in(&own, "pcx:studio:acp:fork-test").expect("key");
    let view = fake_conn_at(&key, 4, &format!("http://{}/", gateway.addr));
    lock(&view).host_id = "h".into();
    let link = link_of(&key);

    script(&gateway).fork = Some((
        "200 OK",
        json!({"outcome": "created", "sessionId": "new", "cwd": "/w", "title": "T",
            "forkedFrom": "s", "lastTurnInterrupted": true, "boundaryConfirmed": true}),
    ));
    let ForkOutcome::Created(fork) = ops::fork(&link, "s", Some("t1")).expect("created") else {
        panic!("expected a new session");
    };
    assert_eq!((fork.thread.id.as_str(), fork.thread.cwd.as_str()), ("new", "/w"));
    assert_eq!(fork.thread.forked_from_id.as_deref(), Some("s"));
    assert_eq!(fork.thread.parent_thread_id, None, "a fork is not a spawned agent");
    assert!(fork.last_turn_interrupted && fork.boundary_confirmed);
    let sent = script(&gateway).forked.remove(0);
    assert_eq!(
        sent,
        json!({"sessionId": "s", "throughTurn": "t1", "hostId": "h", "generation": 4}),
        "the shown host's identity travels; no path or prompt does"
    );

    script(&gateway).fork =
        Some(("409 Conflict", json!({"code": "stale_host", "message": "changed"})));
    assert!(ops::fork(&link, "s", None).is_err(), "the host refused: nothing was created");

    script(&gateway).fork = Some(("200 OK", json!({"outcome": "unknown", "reason": "lost"})));
    assert!(matches!(
        ops::fork(&link, "s", None).expect("not a refusal"),
        ForkOutcome::Unknown(reason) if reason == "lost"
    ));

    script(&gateway).fork = None;
    assert!(
        matches!(ops::fork(&link, "s", None).expect("not a refusal"), ForkOutcome::Unknown(_)),
        "a lost answer may follow a created session"
    );
    assert_eq!(script(&gateway).forked.len(), 3, "and nothing was retried");
}
