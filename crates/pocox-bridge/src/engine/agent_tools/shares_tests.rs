//! Tests of [`super`]: requests, ownership and lifetimes of shares.

use super::*;

#[test]
fn requests_name_real_ports_that_are_not_pocox_own() {
    let request = |ports: Vec<u16>| ShareRequest {
        ports,
        ..ShareRequest::default()
    };
    let own = BTreeSet::from([17863, 41000]);
    assert_eq!(validate(&request(vec![5173, 5173, 8000]), &own), Ok(vec![5173, 8000]));
    assert!(validate(&request(vec![]), &own).is_err());
    assert!(validate(&request(vec![0]), &own).is_err());
    assert!(validate(&request(vec![5173, 41000]), &own).is_err());
    assert!(validate(&request(vec![1, 2, 3, 4, 5]), &own).is_err());
}

#[test]
fn the_user_sharing_an_agents_port_makes_that_share_theirs() {
    let mut state = State::default();
    let addr = SocketAddr::from(([127, 0, 0, 1], 5173));
    state.shares.push(Share {
        id: "s1".into(),
        title: "Landing".into(),
        path: "/".into(),
        secure: false,
        owner: Caller::user("agent").owner(),
        key: Some(OwnerKey {
            token: "t1".into(),
            conversation: Some("c1".into()),
        }),
        created_ms: 0,
        expires_ms: Some(1),
        ports: vec![SharedPort::new(5173, "pcx:studio:port:5173".into(), addr, true)],
    });
    take_over(&mut state, &[8000], &Caller::user("You")).expect("nothing to take");
    assert!(state.shares[0].key.is_some(), "other ports are left alone");
    take_over(&mut state, &[5173], &Caller::user("You")).expect("taken");
    let share = &state.shares[0];
    assert!(share.key.is_none() && share.expires_ms.is_none() && share.durable());
}

#[test]
fn a_page_and_its_other_ports_stay_one_share() {
    let addr = |port| SocketAddr::from(([127, 0, 0, 1], port));
    let agent = Caller {
        principal: Principal {
            id: "t1".into(),
            kind: Kind::Hosted,
            label: "Codex".into(),
            harness: Some("codex".into()),
            host: Some("default".into()),
            session: None,
        },
        conversation: Some("c1".into()),
    };
    let share = |id: &str, key: Option<OwnerKey>, port: u16| Share {
        id: id.into(),
        title: "Page".into(),
        path: "/".into(),
        secure: false,
        owner: agent.owner(),
        key,
        created_ms: 0,
        expires_ms: None,
        ports: vec![SharedPort::new(port, format!("pcx:studio:port:{port}"), addr(port), true)],
    };
    let mut state = State::default();
    state.shares.push(share("mine", Some(agent.key()), 5173));
    state.shares.push(share("theirs", None, 8000));
    let user = Caller::user("You");
    // Its own page takes more free ports; a port held apart does not join.
    assert!(refuse_split(&state, &agent, &agent.key(), &[5173, 9000]).is_ok());
    assert!(refuse_split(&state, &agent, &agent.key(), &[5173, 8000]).is_err());
    assert!(refuse_split(&state, &agent, &agent.key(), &[3000, 8000]).is_err());
    // Someone else's page takes no ports from an agent; the user's ask may.
    assert!(refuse_split(&state, &agent, &agent.key(), &[8000, 9000]).is_err());
    assert!(refuse_split(&state, &user, &user.key(), &[8000, 9000]).is_ok());
}

#[test]
fn only_published_ports_of_the_users_shares_are_saved() {
    let addr = |port| SocketAddr::from(([127, 0, 0, 1], port));
    let pending = |port| SharedPort {
        confirmed: false,
        ..SharedPort::new(port, format!("pcx:studio:port:{port}"), addr(port), true)
    };
    let mut share = Share {
        id: "s1".into(),
        title: "Landing".into(),
        path: "/".into(),
        secure: false,
        owner: Caller::user("You").owner(),
        key: None,
        created_ms: 0,
        expires_ms: None,
        ports: vec![pending(5173)],
    };
    assert!(!share.durable(), "a share still publishing is not saved");
    share
        .ports
        .insert(0, SharedPort::new(5173, "pcx:studio:port:5173".into(), addr(5173), true));
    share.ports[1] = pending(8000);
    assert_eq!(share.saved().ports, [5173], "its companion joins once published");
}
