part of '../bridge_api_rust.dart';

/// One native projection whose conversation filter moves in place.
class _NativeEventFeed implements AppEventFeed {
  factory _NativeEventFeed(
    String serviceKey,
    String? threadId,
    EventTopic topic,
  ) {
    final native = frb.eventFeedCreate(threadId: threadId);
    final events = frb
        .appProjectedEvents(
          serviceKey: serviceKey,
          feed: native,
          topic: frb.EventTopic.values.byName(topic.name),
        )
        .map(_appEvent);
    return _NativeEventFeed._(native, events);
  }

  _NativeEventFeed._(this._native, this.events);

  final frb.EventFeed _native;

  @override
  final Stream<AppEvent> events;

  @override
  void follow(String? threadId) =>
      frb.eventFeedFollow(feed: _native, threadId: threadId);
}

AppEvent _appEvent(frb.AppEventDto e) => AppEvent(
  kind: e.kind,
  threadId: e.threadId,
  itemId: e.itemId,
  itemType: e.itemType,
  title: e.title,
  text: e.text,
  images: e.images,
  requestId: e.requestId,
  raw: e.raw,
  turnId: e.turnId,
  sender: e.sender,
  textIsSnapshot: e.textIsSnapshot,
  running: e.running,
  diff: e.diff == null ? null : DiffModel.fromNative(e.diff!),
);
