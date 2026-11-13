//! FUNTIDESK (ADR-024, stage 5): reads a Windows event log, newest first,
//! with the message text the way Event Viewer shows it.

use super::eventlog_rules::{self as rules, Event, Request};
use std::collections::HashMap;
use windows::{
    core::{HSTRING, PCWSTR},
    Win32::System::EventLog::{
        EvtClose, EvtFormatMessage, EvtFormatMessageEvent, EvtNext, EvtOpenPublisherMetadata, EvtQuery,
        EvtQueryChannelPath, EvtQueryReverseDirection, EvtRender, EvtRenderEventXml, EVT_HANDLE,
    },
};

/// Closes the handle when dropped.
struct Handle(EVT_HANDLE);

impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_invalid() {
            unsafe { EvtClose(self.0).ok() };
        }
    }
}

/// The JSON answer, or an error answer if the log cannot be read.
pub fn read(request: &Request) -> String {
    match events(request) {
        Ok(events) => rules::events_json(request, &events).to_string(),
        Err(e) => {
            hbb_common::log::info!("FuntiDesk event log {}: {}", request.log.channel(), e);
            super::rules::error_json("eventlog", "funti-admin-eventlog-failed").to_string()
        }
    }
}

fn events(request: &Request) -> windows::core::Result<Vec<Event>> {
    let query = Handle(unsafe {
        EvtQuery(
            None,
            &HSTRING::from(request.log.channel()),
            &HSTRING::from(request.level.query()),
            EvtQueryChannelPath.0 | EvtQueryReverseDirection.0,
        )?
    });
    // Message templates of each source, opened once per answer.
    let mut publishers: HashMap<String, Option<Handle>> = HashMap::new();
    let mut out = Vec::new();
    let mut batch = [0isize; 32];
    while out.len() < request.count {
        let mut returned = 0u32;
        // Fails with ERROR_NO_MORE_ITEMS at the end of the log.
        if unsafe { EvtNext(query.0, &mut batch, 2000, 0, &mut returned) }.is_err() {
            break;
        }
        for raw in &batch[..returned as usize] {
            let event = Handle(EVT_HANDLE(*raw));
            if out.len() >= request.count {
                continue;
            }
            let Some(xml) = render_xml(&event) else { continue };
            let mut e = rules::parse_system(&xml);
            let publisher = publishers.entry(e.source.clone()).or_insert_with(|| {
                unsafe { EvtOpenPublisherMetadata(None, &HSTRING::from(e.source.as_str()), PCWSTR::null(), 0, 0) }
                    .ok()
                    .map(Handle)
            });
            e.message = rules::clip_message(&message(publisher.as_ref(), &event).unwrap_or_default());
            out.push(e);
        }
    }
    Ok(out)
}

fn render_xml(event: &Handle) -> Option<String> {
    let (mut used, mut properties) = (0u32, 0u32);
    // The first call tells the size.
    let _ = unsafe { EvtRender(None, event.0, EvtRenderEventXml.0, 0, None, &mut used, &mut properties) };
    if used == 0 {
        return None;
    }
    let mut buffer = vec![0u16; (used as usize + 1) / 2 + 1];
    unsafe {
        EvtRender(
            None,
            event.0,
            EvtRenderEventXml.0,
            (buffer.len() * 2) as u32,
            Some(buffer.as_mut_ptr() as *mut _),
            &mut used,
            &mut properties,
        )
    }
    .ok()?;
    Some(wide(&buffer))
}

fn message(publisher: Option<&Handle>, event: &Handle) -> Option<String> {
    let publisher = publisher?;
    let mut used = 0u32;
    let _ = unsafe {
        EvtFormatMessage(Some(publisher.0), Some(event.0), 0, None, EvtFormatMessageEvent.0, None, &mut used)
    };
    if used == 0 {
        return None;
    }
    let mut buffer = vec![0u16; used as usize];
    unsafe {
        EvtFormatMessage(
            Some(publisher.0),
            Some(event.0),
            0,
            None,
            EvtFormatMessageEvent.0,
            Some(&mut buffer),
            &mut used,
        )
    }
    .ok()?;
    Some(wide(&buffer))
}

fn wide(buffer: &[u16]) -> String {
    let end = buffer.iter().position(|c| *c == 0).unwrap_or(buffer.len());
    String::from_utf16_lossy(&buffer[..end])
}
