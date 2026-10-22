use tokio::sync::{broadcast, mpsc, watch};

use super::{accepts, forward_projected_events, EventTopic};
use crate::engine::app_session::AppEvent;

fn event(kind: &str) -> AppEvent {
    AppEvent {
        kind: kind.into(),
        thread_id: Some("thread".into()),
        item_id: None,
        item_type: None,
        title: None,
        text: None,
        images: Vec::new(),
        request_id: None,
        raw: "{}".into(),
    }
}

fn on(thread: &str, kind: &str) -> AppEvent {
    AppEvent {
        thread_id: Some(thread.into()),
        ..event(kind)
    }
}

async fn forward(rx: broadcast::Receiver<AppEvent>, keep: usize) -> Vec<AppEvent> {
    let mut received = Vec::new();
    tokio::time::timeout(
        std::time::Duration::from_secs(1),
        forward_projected_events(rx, watch::channel(None).1, EventTopic::All, |update| {
            received.push(update.event);
            received.len() < keep
        }),
    )
    .await
    .expect("the feed ends without waiting for the socket to close");
    received
}

#[tokio::test]
async fn forwards_in_order_until_the_dart_listener_leaves() {
    let feed = || {
        let (tx, rx) = broadcast::channel(4);
        for kind in ["item/completed", "turn/completed"] {
            tx.send(event(kind)).unwrap();
        }
        (tx, rx)
    };
    let kinds = |events: Vec<AppEvent>| events.into_iter().map(|e| e.kind).collect::<Vec<_>>();
    let (tx, rx) = feed();
    drop(tx);
    assert_eq!(kinds(forward(rx, usize::MAX).await), ["item/completed", "turn/completed"]);
    let (tx, rx) = feed();
    assert_eq!(kinds(forward(rx, 1).await), ["item/completed"]);
    assert_eq!(tx.receiver_count(), 0);
}

#[tokio::test]
async fn a_gap_closes_the_feed_but_preserves_retained_prompts() {
    let (tx, rx) = broadcast::channel(4);
    tx.send(event("lost-item")).unwrap();
    for (kind, id) in [
        ("item/commandExecution/requestApproval", "approval-1"),
        ("item/tool/requestUserInput", "question-1"),
    ] {
        let mut prompt = event(kind);
        prompt.request_id = Some(id.into());
        tx.send(prompt).unwrap();
    }
    tx.send(event("item/completed")).unwrap();
    tx.send(event("turn/completed")).unwrap();
    let received = forward(rx, usize::MAX).await;
    let prompts: Vec<_> = received
        .into_iter()
        .map(|e| (e.kind, e.request_id))
        .collect();
    assert_eq!(prompts, vec![
        ("item/commandExecution/requestApproval".into(), Some("approval-1".into())),
        ("item/tool/requestUserInput".into(), Some("question-1".into())),
    ]);
    // A partial tail is never delivered, and the connection stays usable.
    assert_eq!(tx.receiver_count(), 0);
    let mut resumed = tx.subscribe();
    tx.send(event("turn/started")).unwrap();
    assert_eq!(resumed.recv().await.unwrap().kind, "turn/started");
}

#[tokio::test]
async fn projection_coalesces_text_without_reordering_approvals_or_completion() {
    let (tx, rx) = broadcast::channel(8);
    let mut started = event("item/started");
    started.item_id = Some("item".into());
    started.item_type = Some("agentMessage".into());
    started.text = Some("prefix".into());
    tx.send(started.clone()).unwrap();
    for text in [" one", " two"] {
        let mut delta = started.clone();
        delta.kind = "item/agentMessage/delta".into();
        delta.text = Some(text.into());
        tx.send(delta).unwrap();
    }
    let mut approval = event("item/commandExecution/requestApproval");
    approval.request_id = Some("approval".into());
    tx.send(approval).unwrap();
    tx.send(event("turn/completed")).unwrap();
    drop(tx);
    let mut received = Vec::new();
    let thread = watch::channel(Some("thread".into())).1;
    forward_projected_events(rx, thread, EventTopic::All, |event| {
        received.push(event);
        true
    })
    .await;
    assert_eq!(received.len(), 4);
    assert_eq!(received[1].event.text.as_deref(), Some("prefix one two"));
    assert!(received[1].text_is_snapshot);
    assert_eq!(received[2].event.request_id.as_deref(), Some("approval"));
    assert_eq!(received[3].event.kind, "turn/completed");
}

#[tokio::test]
async fn following_another_thread_retargets_the_running_feed() {
    let (tx, rx) = broadcast::channel(8);
    let (follow, thread) = watch::channel(Some("a".to_string()));
    let (out, mut delivered) = mpsc::unbounded_channel();
    tokio::spawn(forward_projected_events(rx, thread, EventTopic::All, move |update| {
        out.send((update.event.thread_id, update.event.kind))
            .is_ok()
    }));
    tx.send(on("b", "item/completed")).unwrap();
    tx.send(on("b", "turn/completed")).unwrap();
    tx.send(on("a", "item/completed")).unwrap();
    let (thread, kind) = delivered.recv().await.unwrap();
    assert_eq!((thread.as_deref(), kind.as_str()), (Some("b"), "turn/completed"));
    assert_eq!(delivered.recv().await.unwrap().0.as_deref(), Some("a"));
    follow.send_replace(Some("b".into()));
    tx.send(on("a", "item/completed")).unwrap();
    tx.send(on("b", "item/completed")).unwrap();
    assert_eq!(delivered.recv().await.unwrap().0.as_deref(), Some("b"));
    // The `a` item between the two was judged by the new thread.
    assert!(delivered.try_recv().is_err());
}

#[test]
fn topics_keep_what_their_listener_acts_on() {
    let started = on("dictation", "turn/started");
    assert!(accepts(&started, Some("dictation"), EventTopic::Realtime));
    assert!(!accepts(&on("other", "turn/started"), Some("dictation"), EventTopic::Realtime));
    assert!(!accepts(&on("dictation", "item/completed"), Some("dictation"), EventTopic::Realtime));
    assert!(accepts(&on("other", "turn/failed"), Some("shown"), EventTopic::All));
    assert!(!accepts(&on("shown", "item/agentMessage/delta"), None, EventTopic::Activity));
}
