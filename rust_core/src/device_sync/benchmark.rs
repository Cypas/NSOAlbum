//! Debug benchmark eligibility is stricter than a directional merge no-op.
//! Compare synchronized business records, never local storage/header identity.
use std::collections::BTreeMap;

use super::{manifest::FAVORITES_UUID, receiver::Snapshot};

pub(crate) fn business_equivalent(source: &Snapshot, target: &Snapshot) -> bool {
    let (Ok(mut source_data), Ok(mut target_data)) =
        (source.manifest.validate(), target.manifest.validate())
    else {
        return false;
    };
    // A physical original can retain .jpeg versus .jpg on the receiving volume.
    // All other media fields, including displayed name and both times, remain.
    for data in [&mut source_data, &mut target_data] {
        for media in data.media.values_mut() {
            media.extension.clear();
        }
        if let Some(favorites) = data.albums.get_mut(FAVORITES_UUID) {
            // The one built-in favorites album is independently owned locally.
            if favorites.definition.source_library_uuid == data.header.library_uuid {
                favorites.definition.source_library_uuid.clear();
            }
        }
    }
    if source_data.media != target_data.media
        || source_data.albums != target_data.albums
        || source_data.tags != target_data.tags
        || source_data.mappings != target_data.mappings
    {
        return false;
    }
    // Endpoint device labels are presentation, not synchronized account/media data.
    // Other forwarded provenance names are business data and must agree exactly.
    let excluded = [
        source.manifest.header.library_uuid.as_str(),
        target.manifest.header.library_uuid.as_str(),
    ];
    forwarded(source, excluded) == forwarded(target, excluded)
}

fn forwarded<'a>(snapshot: &'a Snapshot, excluded: [&str; 2]) -> BTreeMap<&'a str, &'a str> {
    snapshot
        .sources
        .entries
        .iter()
        .filter(|entry| !excluded.contains(&entry.library_uuid.as_str()))
        .map(|entry| (entry.library_uuid.as_str(), entry.display_name.as_str()))
        .collect()
}
