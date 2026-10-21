//! CommonMark/GFM parsing projected to Flutter's existing Markdown renderer.
use anyhow::{ensure, Result};
use comrak::{
    nodes::{AstNode, ListType, NodeValue, TableAlignment},
    Arena, Options,
};

type Node = (i32, String, String, Vec<String>);
struct Tree {
    nodes: Vec<Node>,
}

impl Tree {
    fn add(&mut self, parent: i32, tag: &str, text: &str, attrs: Vec<String>) -> Result<i32> {
        ensure!(self.nodes.len() < 16_384, "Markdown node budget exceeded");
        let index = self.nodes.len() as i32;
        self.nodes.push((parent, tag.into(), text.into(), attrs));
        Ok(index)
    }
    fn element(&mut self, parent: i32, tag: &str) -> Result<i32> {
        self.add(parent, tag, "", vec![])
    }
    fn text(&mut self, parent: i32, text: &str) -> Result<()> {
        // Joining adjacent text keeps the Dart adapter small and avoids spans
        // for every soft break and escaped punctuation character.
        if let Some((p, tag, value, _)) = self.nodes.last_mut() {
            if *p == parent && tag.is_empty() {
                value.push_str(text);
                return Ok(());
            }
        }
        self.add(parent, "", text, vec![])?;
        Ok(())
    }
    fn children<'a>(&mut self, node: &'a AstNode<'a>, parent: i32, depth: usize) -> Result<()> {
        for child in node.children() {
            self.node(child, parent, depth + 1)?;
        }
        Ok(())
    }
    fn node<'a>(&mut self, node: &'a AstNode<'a>, parent: i32, depth: usize) -> Result<()> {
        ensure!(depth <= 128, "Markdown nesting budget exceeded");
        let value = &node.data.borrow().value;
        let tag = match value {
            NodeValue::Document => return self.children(node, parent, depth),
            NodeValue::Text(text) => return self.text(parent, text),
            NodeValue::EscapedTag(text) => return self.text(parent, text),
            NodeValue::SoftBreak => return self.text(parent, "\n"),
            NodeValue::HtmlInline(text) | NodeValue::Raw(text) => return self.text(parent, text),
            NodeValue::HtmlBlock(block) => {
                return self
                    .text(parent, block.literal.strip_suffix('\n').unwrap_or(&block.literal))
            },
            NodeValue::Code(code) => {
                let at = self.element(parent, "code")?;
                return self.text(at, &code.literal);
            },
            NodeValue::CodeBlock(code) => {
                let pre = self.element(parent, "pre")?;
                let mut attrs = vec![];
                if let Some(language) = code.info.split_whitespace().next() {
                    attrs.extend(["class".into(), format!("language-{language}")]);
                }
                let at = self.add(pre, "code", "", attrs)?;
                return self.text(at, &code.literal);
            },
            NodeValue::List(list) => {
                let ordered = list.list_type == ListType::Ordered;
                let attrs =
                    if ordered { vec!["start".into(), list.start.to_string()] } else { vec![] };
                let at = self.add(parent, if ordered { "ol" } else { "ul" }, "", attrs)?;
                return self.children(node, at, depth);
            },
            NodeValue::TaskItem(item) => {
                let at = self.element(parent, "li")?;
                let mut attrs = vec!["type".into(), "checkbox".into()];
                if item.symbol.is_some() {
                    attrs.extend(["checked".into(), "true".into()]);
                }
                let mut children = node.children();
                if let Some(first) = children.next() {
                    if matches!(first.data.borrow().value, NodeValue::Paragraph)
                        && !tight_item(first)
                    {
                        let paragraph = self.element(at, "p")?;
                        self.add(paragraph, "input", "", attrs)?;
                        self.children(first, paragraph, depth + 1)?;
                    } else {
                        self.add(at, "input", "", attrs)?;
                        self.node(first, at, depth + 1)?;
                    }
                    for child in children {
                        self.node(child, at, depth + 1)?;
                    }
                } else {
                    self.add(at, "input", "", attrs)?;
                }
                return Ok(());
            },
            NodeValue::Paragraph if tight_item(node) => return self.children(node, parent, depth),
            NodeValue::Link(link) => {
                let mut attrs = vec!["href".into(), link.url.clone()];
                if !link.title.is_empty() {
                    attrs.extend(["title".into(), link.title.clone()]);
                }
                let at = self.add(parent, "a", "", attrs)?;
                return self.children(node, at, depth);
            },
            NodeValue::Image(link) => {
                let mut alt = String::new();
                for child in node.descendants() {
                    match &child.data.borrow().value {
                        NodeValue::Text(text) => alt.push_str(text),
                        NodeValue::Code(code) => alt.push_str(&code.literal),
                        NodeValue::SoftBreak | NodeValue::LineBreak => alt.push('\n'),
                        _ => {},
                    }
                }
                self.add(parent, "img", "", vec![
                    "src".into(),
                    link.url.clone(),
                    "alt".into(),
                    alt,
                    "title".into(),
                    link.title.clone(),
                ])?;
                return Ok(());
            },
            NodeValue::Table(table) => return self.table(node, parent, depth, &table.alignments),
            NodeValue::Heading(heading) => {
                let at = self.element(parent, &format!("h{}", heading.level))?;
                return self.children(node, at, depth);
            },
            NodeValue::BlockQuote => "blockquote",
            NodeValue::Item(_) => "li",
            NodeValue::Paragraph => "p",
            NodeValue::ThematicBreak => "hr",
            NodeValue::LineBreak => "br",
            NodeValue::Emph => "em",
            NodeValue::Strong => "strong",
            NodeValue::Strikethrough => "del",
            _ => return self.children(node, parent, depth),
        };
        let at = self.element(parent, tag)?;
        self.children(node, at, depth)
    }
    fn table<'a>(
        &mut self,
        node: &'a AstNode<'a>,
        parent: i32,
        depth: usize,
        align: &[TableAlignment],
    ) -> Result<()> {
        let table = self.element(parent, "table")?;
        let mut body = None;
        for row in node.children() {
            let header = matches!(row.data.borrow().value, NodeValue::TableRow(true));
            let group = if header {
                self.element(table, "thead")?
            } else if let Some(body) = body {
                body
            } else {
                let at = self.element(table, "tbody")?;
                body = Some(at);
                at
            };
            let tr = self.element(group, "tr")?;
            for (i, cell) in row.children().enumerate() {
                let alignment = match align.get(i) {
                    Some(TableAlignment::Left) => "left",
                    Some(TableAlignment::Right) => "right",
                    Some(TableAlignment::Center) => "center",
                    _ => "",
                };
                let attrs = if alignment.is_empty() {
                    vec![]
                } else {
                    vec!["align".into(), alignment.into()]
                };
                let at = self.add(tr, if header { "th" } else { "td" }, "", attrs)?;
                self.children(cell, at, depth + 3)?;
            }
        }
        Ok(())
    }
}

fn tight_item<'a>(node: &'a AstNode<'a>) -> bool {
    node.parent().and_then(|p| p.parent()).is_some_and(
        |list| matches!(&list.data.borrow().value, NodeValue::List(list) if list.tight),
    )
}

fn autolinkify(source: &str) -> String {
    let mut result = String::with_capacity(source.len());
    let mut previous = '\0';
    for (at, ch) in source.char_indices() {
        if matches!(previous, '\u{3000}'..='\u{303f}' | '\u{4e00}'..='\u{9fff}' | '\u{ff00}'..='\u{ffef}')
            && (source[at..].starts_with("http://") || source[at..].starts_with("https://"))
        {
            result.push(' ');
        }
        result.push(ch);
        previous = ch;
    }
    result
}

/// Parse a source into flat renderer nodes; no HTML is executed or fetched.
pub fn parse(source: &str) -> Result<String> {
    ensure!(source.len() <= 1 << 20, "Markdown source exceeds its byte budget");
    let mut options = Options::default();
    options.extension.table = true;
    options.extension.strikethrough = true;
    options.extension.tasklist = true;
    options.extension.autolink = true;
    options.extension.cjk_friendly_emphasis = true;
    let arena = Arena::new();
    let source = autolinkify(source);
    let root = comrak::parse_document(&arena, &source, &options);
    let mut tree = Tree {
        nodes: Vec::new(),
    };
    tree.node(root, -1, 0)?;
    Ok(serde_json::to_string(&tree.nodes)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn gfm_and_cjk_project_to_the_existing_render_contract() {
        let source = "**重点：**中文 [**链接**](https://example.com)\n\n- [x] done\n- task\n\n| a \
                      | b |\n| --- | ---: |\n| x | y |\n\n```rs\nlet x = \"😀\";\n";
        let nodes: Vec<Node> = serde_json::from_str(&parse(source).unwrap()).unwrap();
        for tag in ["strong", "a", "input", "table", "thead", "tbody", "pre", "code"] {
            assert!(nodes.iter().any(|n| n.1 == tag), "{tag}");
        }
        for (index, node) in nodes.iter().enumerate() {
            assert!(node.0 < index as i32);
        }
        assert!(nodes.iter().any(|n| n.2 == "重点："));
        assert!(nodes.iter().any(|n| n.3 == ["class", "language-rs"]));
        assert!(nodes.iter().any(|n| n.2.contains("😀")));
    }
    #[test]
    fn malformed_and_large_sources_have_bounded_projection() {
        assert!(parse(&"a".repeat((1 << 20) + 1)).is_err());
        assert!(parse(&format!("{}x", "> ".repeat(160))).is_err());
        assert!(parse(&"a\n\n".repeat(10_000)).is_err());
        assert!(parse("`**重点：**中文`\n\n<script>alert(1)</script>")
            .unwrap()
            .contains("<script>"));
    }
}
