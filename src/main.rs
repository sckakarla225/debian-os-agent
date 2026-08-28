use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Layout};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Paragraph};
use ratatui::Frame;

struct AppState { prompt: String, status: String }

impl Default for AppState {
    fn default() -> Self {
        Self {
            prompt: String::new(),
            status: "ready".to_string(),
        }
    }
}

fn main() -> std::io::Result<()> {
    ratatui::run(|terminal| {
        let mut app = AppState::default();

        loop {
            terminal.draw(|frame| render(frame, &app))?;
            if handle_event(&mut app)? {
                break Ok(());
            }
        }
    })
}

fn render(frame: &mut Frame, app: &AppState) {
    let [header, body, input_area, footer] = Layout::vertical([
        Constraint::Length(3),
        Constraint::Min(0),
        Constraint::Length(3),
        Constraint::Length(1),
    ])
    .areas(frame.area());

    frame.render_widget(
        Block::bordered().title("debian-os-agent"),
        header,
    );

    frame.render_widget(
        Paragraph::new(format!(
            "Type in the prompt below.\nEnter to submit · Ctrl+Q to quit\n\nLast input: {}",
            if app.prompt.is_empty() {
                "(none)".to_string()
            } else {
                app.prompt.clone()
            }
        )),
        body,
    );

    render_input(frame, app, input_area);

    frame.render_widget(
        Paragraph::new(format!("Status: {}", app.status)),
        footer,
    );
}

fn render_input(frame: &mut Frame, app: &AppState, area: ratatui::layout::Rect) {
    const PROMPT: &str = "> ";

    let block = Block::bordered().title("Prompt");
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let line = Line::from(vec![
        Span::styled(PROMPT, Style::new().add_modifier(Modifier::DIM)),
        Span::raw(&app.prompt),
    ]);
    frame.render_widget(Paragraph::new(line), inner);

    // Place the terminal cursor at the end of the typed text.
    let cursor_x = inner.x + PROMPT.len() as u16 + app.prompt.chars().count() as u16;
    frame.set_cursor_position((
        cursor_x.min(inner.right().saturating_sub(1)),
        inner.y,
    ));
}

fn handle_event(app: &mut AppState) -> std::io::Result<bool> {
    let Event::Key(key) = event::read()? else {
        return Ok(false);
    };

    if key.kind != KeyEventKind::Press {
        return Ok(false);
    }

    if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('q') {
        return Ok(true);
    }

    match key.code {
        KeyCode::Char(c) => {
            app.prompt.push(c);
            app.status = "typing".to_string();
        }
        KeyCode::Backspace => {
            app.prompt.pop();
            app.status = if app.prompt.is_empty() {
                "ready".to_string()
            } else {
                "typing".to_string()
            };
        }
        KeyCode::Enter => {
            app.status = if app.prompt.is_empty() {
                "ready".to_string()
            } else {
                format!("submitted ({})", app.prompt.len())
            };
            // Keep `app.input` so you can read/submit it here (API call, command, etc.).
        }
        KeyCode::Esc => {
            app.prompt.clear();
            app.status = "ready".to_string();
        }
        _ => {}
    }

    Ok(false)
}