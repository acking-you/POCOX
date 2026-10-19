//! Typed OpenCode 2 responses, moved into the 1.x shapes the host reads.
//! Only fields the host uses are decoded; values move, they are not copied.

use serde::Deserialize;
use serde_json::{json, Map, Value};

use crate::opencode::{
    catalog::{self, Catalog, CatalogModel},
    client::ClientError,
    schema::{self, SessionTime},
};

#[derive(Deserialize)]
pub(super) struct Data<T> {
    pub data: T,
}

#[derive(Deserialize)]
pub(super) struct Page<T> {
    pub data: Vec<T>,
    #[serde(default)]
    cursor: Cursor,
}

#[derive(Default, Deserialize)]
struct Cursor {
    next: Option<String>,
}

impl<T> Page<T> {
    /// The cursor to older items. V2 sends one after every non-empty page, so
    /// a page shorter than requested is the end.
    pub fn next(&mut self, requested: usize) -> Result<Option<String>, ClientError> {
        match self.cursor.next.take() {
            Some(cursor) if cursor.len() > 4096 => Err(ClientError::InvalidResponse),
            next if self.data.len() >= requested => Ok(next),
            _ => Ok(None),
        }
    }
}

#[derive(Deserialize)]
pub(super) struct Info {
    pub version: String,
}

#[derive(Deserialize)]
pub(super) struct Interrupted {
    pub interrupted: bool,
}

#[derive(Deserialize)]
pub(super) struct Session {
    id: String,
    title: Option<String>,
    location: Location,
    #[serde(rename = "parentID")]
    parent_id: Option<String>,
    time: SessionTime,
}

#[derive(Deserialize)]
struct Location {
    directory: String,
}

impl From<Session> for schema::Session {
    fn from(session: Session) -> Self {
        Self {
            id: session.id,
            title: session.title.unwrap_or_default(),
            directory: session.location.directory,
            parent_id: session.parent_id,
            time: session.time,
        }
    }
}

#[derive(Deserialize)]
pub(super) struct Provider {
    id: String,
    name: String,
    activation: String,
}

#[derive(Deserialize)]
pub(super) struct Model {
    id: String,
    #[serde(rename = "providerID")]
    provider_id: String,
    name: String,
    variants: Vec<Variant>,
    status: String,
    enabled: bool,
    #[serde(default)]
    capabilities: Capabilities,
}

#[derive(Deserialize)]
struct Variant {
    id: String,
}

#[derive(Default, Deserialize)]
struct Capabilities {
    input: Vec<String>,
}

/// `data` is absent, not null, when no default model is configured.
#[derive(Deserialize)]
pub(super) struct DefaultModel {
    data: Option<ModelRef>,
}

#[derive(Deserialize)]
struct ModelRef {
    id: String,
    #[serde(rename = "providerID")]
    provider_id: String,
    variant: Option<String>,
}

#[derive(Deserialize)]
pub(super) struct Agent {
    id: String,
    description: Option<String>,
    mode: String,
    hidden: bool,
}

#[derive(Deserialize)]
pub(super) struct Command {
    name: String,
    description: Option<String>,
}

pub(super) fn catalog(
    providers: Vec<Provider>,
    models: Vec<Model>,
    default: DefaultModel,
    agents: Vec<Agent>,
    commands: Vec<Command>,
) -> Catalog {
    // `/api/model` lists the usable models; `/api/provider` lists only
    // configured providers, so it names them or turns one off, nothing more.
    let models: Vec<_> = models
        .into_iter()
        .filter(|model| model.enabled && model.status != "deprecated")
        .filter_map(|model| {
            let provider = providers.iter().find(|p| p.id == model.provider_id);
            if provider.is_some_and(|provider| provider.activation == "disabled") {
                return None;
            }
            Some(CatalogModel {
                provider_name: provider
                    .map_or_else(|| model.provider_id.clone(), |p| p.name.clone()),
                provider: model.provider_id,
                id: model.id,
                name: model.name,
                variants: model.variants.into_iter().map(|v| v.id).collect(),
                images: model.capabilities.input.iter().any(|kind| kind == "image"),
            })
        })
        .collect();
    let mut connected: Vec<_> = models.iter().map(|model| &model.provider).collect();
    connected.sort();
    connected.dedup();
    let connected = connected.len();
    let agents = agents
        .into_iter()
        .filter(|agent| !agent.hidden && agent.mode != "subagent")
        .map(|agent| catalog::Agent {
            // The ID is what the agent selection route accepts.
            name: agent.id,
            description: agent.description,
        })
        .collect();
    let commands = commands
        .into_iter()
        .map(|command| catalog::Command {
            name: command.name,
            description: command.description,
            source: "command".into(),
            hints: Vec::new(),
        })
        .collect();
    let defaults = default
        .data
        .map(|model| (model.provider_id, model.id))
        .into_iter()
        .collect();
    Catalog::assemble(models, agents, commands, defaults, connected)
}

#[derive(Deserialize)]
pub(super) struct Permission {
    id: String,
    #[serde(rename = "sessionID")]
    session_id: String,
    action: String,
    resources: Vec<String>,
    #[serde(default)]
    save: Vec<String>,
}

impl Permission {
    pub fn into_native(self) -> Value {
        object([
            ("id", self.id.into()),
            ("sessionID", self.session_id.into()),
            ("permission", self.action.into()),
            ("patterns", self.resources.into()),
            ("always", self.save.into()),
        ])
    }
}

#[derive(Deserialize)]
pub(super) struct Form {
    id: String,
    #[serde(rename = "sessionID")]
    session_id: String,
    title: String,
    fields: Vec<Field>,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum Field {
    String(Choice),
    Multiselect(Choice),
    #[serde(other)]
    Other,
}

#[derive(Deserialize)]
struct Choice {
    key: String,
    title: Option<String>,
    description: Option<String>,
    #[serde(default)]
    options: Vec<FormOption>,
    #[serde(default)]
    custom: bool,
}

#[derive(Deserialize)]
struct FormOption {
    value: String,
    label: String,
    description: Option<String>,
}

impl Field {
    fn choice(&self) -> Option<(&Choice, bool)> {
        match self {
            Self::String(choice) => Some((choice, false)),
            Self::Multiselect(choice) => Some((choice, true)),
            Self::Other => None,
        }
    }
}

impl Choice {
    /// A field without options takes free text.
    fn free(&self) -> bool {
        self.custom || self.options.is_empty()
    }

    fn question(&self, multiple: bool) -> Value {
        let header = self.title.as_deref().unwrap_or(&self.key);
        json!({"question": self.description.as_deref().unwrap_or(header), "header": header,
            "multiple": multiple, "custom": self.free(),
            "options": self.options.iter()
                .map(|option| json!({"label": option.label, "description": option.description}))
                .collect::<Vec<_>>()})
    }

    fn value(&self, label: &str) -> Option<Value> {
        match self.options.iter().find(|option| option.label == label) {
            Some(option) => Some(option.value.as_str().into()),
            None => self.free().then(|| label.into()),
        }
    }
}

impl Form {
    /// The 1.x question card. A form with a field this card cannot express
    /// becomes one card that can only be rejected.
    pub fn into_native(self) -> Value {
        let questions = self
            .fields
            .iter()
            .map(|field| {
                field
                    .choice()
                    .map(|(choice, multiple)| choice.question(multiple))
            })
            .collect::<Option<Vec<_>>>()
            .unwrap_or_else(|| {
                vec![json!({"question": "This OpenCode form cannot be answered here. Reject it to \
                    continue.", "header": self.title, "multiple": false, "custom": false,
                    "options": []})]
            });
        object([
            ("id", self.id.into()),
            ("sessionID", self.session_id.into()),
            ("questions", questions.into()),
        ])
    }

    /// Map card labels back to the form's field values.
    pub fn answer(self, answers: &[Vec<String>]) -> Result<Map<String, Value>, ClientError> {
        if self.fields.len() != answers.len() {
            return Err(ClientError::UnsupportedForm);
        }
        let mut answer = Map::new();
        for (field, labels) in self.fields.into_iter().zip(answers) {
            let (choice, multiple) = match field {
                Field::String(choice) => (choice, false),
                Field::Multiselect(choice) => (choice, true),
                Field::Other => return Err(ClientError::UnsupportedForm),
            };
            let mut values = labels
                .iter()
                .map(|label| choice.value(label).ok_or(ClientError::UnsupportedForm))
                .collect::<Result<Vec<_>, _>>()?;
            let value = match (multiple, values.len()) {
                (true, _) => Value::Array(values),
                (false, 1) => values.remove(0),
                _ => return Err(ClientError::UnsupportedForm),
            };
            answer.insert(choice.key, value);
        }
        Ok(answer)
    }
}

/// One history item. Selection, location, system, shell, skill and
/// compaction markers have no 1.x conversation form and are skipped.
#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
#[allow(
    clippy::large_enum_variant,
    reason = "items live for one page of at most 200; boxing adds an allocation per message"
)]
pub(super) enum Message {
    User(User),
    Assistant(Assistant),
    Idle(Idle),
    #[serde(other)]
    Other,
}

/// The end of a run, with the error that ended it.
#[derive(Deserialize)]
pub(super) struct Idle {
    id: String,
    outcome: String,
    error: Option<Error>,
    time: Value,
}

#[derive(Deserialize)]
pub(super) struct User {
    id: String,
    text: String,
    #[serde(default)]
    files: Vec<Attached>,
    time: Value,
}

/// A prompt attachment. V2 keeps its bytes; only a path attachment names a
/// URI.
#[derive(Deserialize)]
struct Attached {
    data: String,
    mime: String,
    source: Source,
    name: Option<String>,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum Source {
    Inline,
    Uri { uri: String },
}

/// Tool output content.
#[derive(Deserialize)]
struct File {
    uri: String,
    mime: Option<String>,
    name: Option<String>,
}

#[derive(Deserialize)]
pub(super) struct Assistant {
    id: String,
    agent: String,
    model: ModelRef,
    content: Vec<Content>,
    finish: Option<String>,
    cost: Option<Value>,
    tokens: Option<Value>,
    error: Option<Error>,
    time: Value,
}

#[derive(Deserialize)]
struct Error {
    #[serde(rename = "type")]
    kind: String,
    message: String,
    status: Option<u16>,
    response: Option<ErrorBody>,
}

#[derive(Deserialize)]
struct ErrorBody {
    body: String,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum Content {
    Text {
        text: String,
    },
    Reasoning {
        text: String,
        #[serde(default)]
        time: Value,
    },
    Tool(Tool),
    #[serde(other)]
    Other,
}

#[derive(Deserialize)]
struct Tool {
    id: String,
    name: String,
    state: ToolState,
    time: Value,
}

#[derive(Deserialize)]
struct ToolState {
    status: String,
    #[serde(default)]
    input: Value,
    #[serde(default)]
    content: Vec<ToolContent>,
    error: Option<Error>,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum ToolContent {
    Text { text: String },
    File(File),
}

/// One newest-first page as 1.x messages, oldest first. V2 assistant
/// messages name neither their prompt nor, on the prompt, its selection: each
/// assistant takes the nearest earlier user message as its parent, and that
/// user message takes the first reply's model and agent. A failed run's
/// error goes to its latest reply, or becomes one when the run failed before
/// answering, as 1.x records it.
pub(super) fn history(session: &str, page: Vec<Message>) -> Vec<schema::Message> {
    let mut native = Vec::with_capacity(page.len());
    let mut parent: Option<String> = None;
    let mut unanswered: Option<usize> = None;
    let mut reply: Option<usize> = None;
    for message in page.into_iter().rev() {
        match message {
            Message::User(user) => {
                parent = Some(user.id.clone());
                unanswered = Some(native.len());
                reply = None;
                native.push(user.into_native(session));
            },
            Message::Assistant(assistant) => {
                if let Some(index) = unanswered.take() {
                    let info = &mut native[index].info;
                    info["agent"] = assistant.agent.as_str().into();
                    info["model"] = assistant.model.native();
                }
                reply = Some(native.len());
                native.push(assistant.into_native(session, parent.as_deref()));
            },
            Message::Idle(Idle {
                id,
                outcome,
                error: Some(error),
                time,
            }) if outcome == "failed" => match reply {
                Some(index) if native[index].info["error"].is_null() => {
                    native[index].info["error"] = error.into_native();
                },
                Some(_) => {},
                None => {
                    reply = Some(native.len());
                    let completed = time["created"].clone();
                    let mut info = object([
                        ("id", id.into()),
                        ("sessionID", session.into()),
                        ("role", "assistant".into()),
                        ("parentID", parent.as_deref().into()),
                        ("finish", "error".into()),
                        ("error", error.into_native()),
                        ("time", time),
                    ]);
                    info["time"]["completed"] = completed;
                    native.push(schema::Message {
                        info,
                        parts: Vec::new(),
                    });
                },
            },
            Message::Idle(_) | Message::Other => {},
        }
    }
    native
}

impl ModelRef {
    fn native(&self) -> Value {
        json!({"providerID": self.provider_id, "modelID": self.id, "variant": self.variant})
    }
}

/// A JSON object from moved values; `json!` would serialize copies.
fn object<const N: usize>(fields: [(&str, Value); N]) -> Value {
    Value::Object(
        fields
            .into_iter()
            .map(|(key, value)| (key.into(), value))
            .collect(),
    )
}

/// The identity every 1.x part carries.
fn part<const N: usize>(
    id: String,
    session: &str,
    message: &str,
    fields: [(&str, Value); N],
) -> Value {
    let mut part = object(fields);
    if let Value::Object(map) = &mut part {
        map.insert("id".into(), id.into());
        map.insert("sessionID".into(), session.into());
        map.insert("messageID".into(), message.into());
    }
    part
}

impl User {
    fn into_native(self, session: &str) -> schema::Message {
        let mut parts = Vec::with_capacity(1 + self.files.len());
        parts.push(part(format!("{}:text", self.id), session, &self.id, [
            ("type", "text".into()),
            ("text", self.text.into()),
        ]));
        for (index, file) in self.files.into_iter().enumerate() {
            parts.push(file.into_file().into_native(
                format!("{}:file:{index}", self.id),
                session,
                &self.id,
            ));
        }
        schema::Message {
            info: object([
                ("id", self.id.into()),
                ("sessionID", session.into()),
                ("role", "user".into()),
                ("time", self.time),
            ]),
            parts,
        }
    }
}

impl Attached {
    /// The 1.x file part: an inline attachment as a data URL, a path
    /// attachment by its URI, as 1.x keeps it.
    fn into_file(self) -> File {
        let uri = match self.source {
            Source::Inline => format!("data:{};base64,{}", self.mime, self.data),
            Source::Uri {
                uri,
            } => uri,
        };
        File {
            uri,
            mime: Some(self.mime),
            name: self.name,
        }
    }
}

impl File {
    fn into_native(self, id: String, session: &str, message: &str) -> Value {
        part(id, session, message, [
            ("type", "file".into()),
            ("url", self.uri.into()),
            ("mime", self.mime.into()),
            ("filename", self.name.into()),
        ])
    }
}

impl Error {
    /// The 1.x provider error shape `public::error` classifies.
    fn into_native(self) -> Value {
        let name = match self.kind.as_str() {
            "aborted" => "MessageAbortedError".into(),
            _ => self.kind,
        };
        object([
            ("name", name.into()),
            (
                "data",
                object([
                    ("statusCode", self.status.into()),
                    ("message", self.message.into()),
                    ("responseBody", self.response.map(|response| response.body).into()),
                ]),
            ),
        ])
    }
}

impl Assistant {
    fn into_native(self, session: &str, parent: Option<&str>) -> schema::Message {
        let parts = self
            .content
            .into_iter()
            .enumerate()
            .filter_map(|(index, content)| content.into_native(session, &self.id, index))
            .collect();
        let mut info = object([
            ("id", self.id.into()),
            ("sessionID", session.into()),
            ("role", "assistant".into()),
            ("parentID", parent.into()),
            ("agent", self.agent.into()),
            ("model", self.model.native()),
            ("providerID", self.model.provider_id.into()),
            ("modelID", self.model.id.into()),
            ("finish", self.finish.into()),
            ("cost", self.cost.unwrap_or_default()),
            ("tokens", self.tokens.unwrap_or_default()),
            ("time", self.time),
        ]);
        if let Some(error) = self.error {
            info["error"] = error.into_native();
        }
        schema::Message {
            info,
            parts,
        }
    }
}

impl Content {
    fn into_native(self, session: &str, message: &str, index: usize) -> Option<Value> {
        // Text and reasoning have no V2 ID; their position in the message is
        // stable, because content is only ever appended.
        let id = format!("{message}:{index}");
        Some(match self {
            Self::Text {
                text,
            } => part(id, session, message, [("type", "text".into()), ("text", text.into())]),
            Self::Reasoning {
                text,
                time,
            } => part(id, session, message, [
                ("type", "reasoning".into()),
                ("text", text.into()),
                ("time", span(&time)),
            ]),
            Self::Tool(tool) => {
                let state = tool.state.into_native(session, message, index, &tool.time);
                part(tool.id.clone(), session, message, [
                    ("type", "tool".into()),
                    ("callID", tool.id.into()),
                    ("tool", tool.name.into()),
                    ("state", state),
                ])
            },
            Self::Other => return None,
        })
    }
}

impl ToolState {
    fn into_native(self, session: &str, message: &str, index: usize, time: &Value) -> Value {
        let mut output = String::new();
        let mut attachments = Vec::new();
        let attachment = format!("{message}:tool:{index}");
        for content in self.content {
            match content {
                ToolContent::Text {
                    text,
                } => {
                    if !output.is_empty() {
                        output.push('\n');
                    }
                    output.push_str(&text);
                },
                ToolContent::File(file) => {
                    let id = format!("{attachment}:{}", attachments.len());
                    attachments.push(file.into_native(id, session, &attachment));
                },
            }
        }
        let status = if self.status == "streaming" { "pending".into() } else { self.status };
        let mut state = object([
            ("status", status.into()),
            ("input", self.input),
            ("output", output.into()),
            ("time", span(time)),
            ("attachments", attachments.into()),
        ]);
        if let Some(error) = self.error {
            state["error"] = error.message.into();
        }
        state
    }
}

/// V2 `created`/`ran`/`completed` as the 1.x `start`/`end` span.
fn span(time: &Value) -> Value {
    let mut span = Map::new();
    if let Some(start) = time.get("ran").or_else(|| time.get("created")) {
        span.insert("start".into(), start.clone());
    }
    if let Some(end) = time.get("completed") {
        span.insert("end".into(), end.clone());
    }
    Value::Object(span)
}
