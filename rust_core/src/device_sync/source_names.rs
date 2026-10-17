//! Display-only provenance labels, separate from manifest revision policy.
use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Deserializer, Serialize};
use sha2::{Digest, Sha256};

use super::manifest::{self, Manifest, MAX_PAGE_BYTES, MAX_PAGE_ITEMS};
use crate::error::CoreResult;

pub const MAX_SOURCES: usize = 1024;
pub const MAX_SOURCE_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SourceDescription {
    pub library_uuid: String,
    pub display_name: String,
}

impl SourceDescription {
    pub fn new(library_uuid: String, display_name: String) -> CoreResult<Self> {
        let value = Self {
            library_uuid,
            display_name,
        };
        value.validate()?;
        Ok(value)
    }

    fn validate(&self) -> CoreResult<()> {
        manifest::validate_uuid(&self.library_uuid)?;
        if self.display_name.trim().is_empty()
            || self.display_name.len() > 512
            || self.display_name.chars().count() > 128
            || self.display_name.chars().any(char::is_control)
        {
            return Err(manifest::invalid("invalid source display name"));
        }
        Ok(())
    }
}

impl<'de> Deserialize<'de> for SourceDescription {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Wire {
            library_uuid: String,
            display_name: String,
        }
        let wire = Wire::deserialize(deserializer)?;
        Self::new(wire.library_uuid, wire.display_name).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceDescriptions {
    pub version: u32,
    pub manifest_digest: String,
    pub entries: Vec<SourceDescription>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceDescriptionPage {
    pub version: u32,
    pub manifest_digest: String,
    pub offset: usize,
    pub total: usize,
    pub entries: Vec<SourceDescription>,
}

impl SourceDescriptionPage {
    pub fn from_json(bytes: &[u8]) -> CoreResult<Self> {
        if bytes.len() > MAX_PAGE_BYTES {
            return Err(manifest::invalid("source page byte limit exceeded"));
        }
        let page: Self = serde_json::from_slice(bytes)?;
        page.validate()?;
        Ok(page)
    }

    pub fn validate(&self) -> CoreResult<()> {
        manifest::validate_sha(&self.manifest_digest)?;
        if self.version != 1
            || self.total > MAX_SOURCES
            || self.offset > self.total
            || self.entries.len() > MAX_PAGE_ITEMS
            || self
                .offset
                .checked_add(self.entries.len())
                .is_none_or(|n| n > self.total)
            || serde_json::to_vec(self)?.len() > MAX_PAGE_BYTES
        {
            return Err(manifest::invalid("invalid source description page"));
        }
        for entry in &self.entries {
            entry.validate()?;
        }
        Ok(())
    }
}

impl SourceDescriptions {
    pub fn new(manifest: &Manifest, entries: Vec<SourceDescription>) -> CoreResult<Self> {
        Self::new_controlled(manifest, entries, &super::work::WorkControl::default())
    }
    fn new_controlled(
        manifest: &Manifest,
        entries: Vec<SourceDescription>,
        work: &super::work::WorkControl,
    ) -> CoreResult<Self> {
        let value = Self {
            version: 1,
            manifest_digest: manifest.validate_controlled(work)?.digest,
            entries,
        };
        value.validate_controlled(manifest, work)?;
        Ok(value)
    }

    pub fn from_json(bytes: &[u8], manifest: &Manifest) -> CoreResult<Self> {
        if bytes.len() > MAX_SOURCE_BYTES {
            return Err(manifest::invalid("source description byte limit exceeded"));
        }
        let value: Self = serde_json::from_slice(bytes)?;
        value.validate(manifest)?;
        Ok(value)
    }

    pub fn validate(&self, manifest: &Manifest) -> CoreResult<()> {
        self.validate_controlled(manifest, &super::work::WorkControl::default())
    }
    pub fn validate_controlled(
        &self,
        manifest: &Manifest,
        work: &super::work::WorkControl,
    ) -> CoreResult<()> {
        let validated = manifest.validate_controlled(work)?;
        if self.version != 1 || self.manifest_digest != validated.digest {
            return Err(manifest::invalid(
                "source descriptions do not match manifest",
            ));
        }
        let mut relevant = BTreeSet::from([manifest.header.library_uuid.as_str()]);
        relevant.extend(
            validated
                .albums
                .values()
                .map(|album| album.definition.source_library_uuid.as_str()),
        );
        let mut seen = BTreeSet::new();
        if self.entries.len() > MAX_SOURCES {
            return Err(manifest::invalid("source description count limit exceeded"));
        }
        for entry in &self.entries {
            work.check()?;
            entry.validate()?;
            if !relevant.contains(entry.library_uuid.as_str()) || !seen.insert(&entry.library_uuid)
            {
                return Err(manifest::invalid(
                    "unrelated or duplicate source description",
                ));
            }
        }
        if serde_json::to_vec(self)?.len() > MAX_SOURCE_BYTES {
            return Err(manifest::invalid("source description byte limit exceeded"));
        }
        Ok(())
    }

    pub fn digest(&self, manifest: &Manifest) -> CoreResult<String> {
        self.digest_controlled(manifest, &super::work::WorkControl::default())
    }
    pub fn digest_controlled(
        &self,
        manifest: &Manifest,
        work: &super::work::WorkControl,
    ) -> CoreResult<String> {
        self.validate_controlled(manifest, work)?;
        let mut canonical = self.clone();
        canonical
            .entries
            .sort_by(|a, b| a.library_uuid.cmp(&b.library_uuid));
        Ok(hex::encode(Sha256::digest(serde_json::to_vec(&canonical)?)))
    }

    pub fn pages(&self, manifest: &Manifest) -> CoreResult<Vec<SourceDescriptionPage>> {
        self.pages_controlled(manifest, &super::work::WorkControl::default())
    }
    pub(crate) fn pages_controlled(
        &self,
        manifest: &Manifest,
        work: &super::work::WorkControl,
    ) -> CoreResult<Vec<SourceDescriptionPage>> {
        self.validate_controlled(manifest, work)?;
        let mut pages = Vec::new();
        let mut offset = 0;
        loop {
            work.check()?;
            let mut page = SourceDescriptionPage {
                version: 1,
                manifest_digest: self.manifest_digest.clone(),
                offset,
                total: self.entries.len(),
                entries: Vec::new(),
            };
            for entry in self.entries.iter().skip(offset).take(MAX_PAGE_ITEMS) {
                page.entries.push(entry.clone());
                if serde_json::to_vec(&page)?.len() > MAX_PAGE_BYTES {
                    page.entries.pop();
                    break;
                }
            }
            if page.entries.is_empty() && offset < self.entries.len() {
                return Err(manifest::invalid("source entry exceeds page budget"));
            }
            offset += page.entries.len();
            pages.push(page);
            if offset == self.entries.len() {
                break;
            }
        }
        Ok(pages)
    }

    pub fn from_pages(pages: Vec<SourceDescriptionPage>, manifest: &Manifest) -> CoreResult<Self> {
        Self::from_pages_controlled(pages, manifest, &super::work::WorkControl::default())
    }
    pub(crate) fn from_pages_controlled(
        pages: Vec<SourceDescriptionPage>,
        manifest: &Manifest,
        work: &super::work::WorkControl,
    ) -> CoreResult<Self> {
        if pages.is_empty()
            || pages.len() > MAX_SOURCES
            || (pages[0].total == 0 && pages.len() != 1)
        {
            return Err(manifest::invalid("invalid source page stream"));
        }
        let digest = manifest.validate_controlled(work)?.digest;
        let total = pages[0].total;
        let mut entries = Vec::new();
        for page in pages {
            work.check()?;
            page.validate()?;
            if page.version != 1
                || page.manifest_digest != digest
                || page.total != total
                || total > MAX_SOURCES
                || page.offset != entries.len()
                || page.entries.len() > MAX_PAGE_ITEMS
                || serde_json::to_vec(&page)?.len() > MAX_PAGE_BYTES
                || (page.entries.is_empty() && total != 0)
                || entries
                    .len()
                    .checked_add(page.entries.len())
                    .is_none_or(|n| n > total)
            {
                return Err(manifest::invalid("invalid source page"));
            }
            entries.extend(page.entries);
        }
        if entries.len() != total {
            return Err(manifest::invalid("incomplete source descriptions"));
        }
        Self::new_controlled(manifest, entries, work)
    }

    pub(crate) fn filtered_controlled(
        manifest: &Manifest,
        known: impl IntoIterator<Item = SourceDescription>,
        work: &super::work::WorkControl,
    ) -> CoreResult<Self> {
        let validated = manifest.validate_controlled(work)?;
        let mut relevant = BTreeSet::from([manifest.header.library_uuid.clone()]);
        relevant.extend(
            validated
                .albums
                .values()
                .map(|a| a.definition.source_library_uuid.clone()),
        );
        let entries: BTreeMap<_, _> = known
            .into_iter()
            .filter(|e| relevant.contains(&e.library_uuid))
            .map(|e| (e.library_uuid.clone(), e))
            .collect();
        Self::new_controlled(manifest, entries.into_values().collect(), work)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Accepting control characters would inject untrusted multiline UI labels.
    #[test]
    fn receiver_source_name_wire_rejects_control_and_oversized_names() {
        for name in [
            "line\nbreak".to_owned(),
            "\u{7f}".to_owned(),
            "x".repeat(129),
        ] {
            let json = serde_json::json!({
                "library_uuid": "10000000-0000-4000-8000-000000000001",
                "display_name": name,
            });
            assert!(
                serde_json::from_value::<SourceDescription>(json).is_err(),
                "an invalid display label was accepted"
            );
        }
    }

    #[test]
    fn receiver_source_pages_reject_duplicate_empty_terminal_pages() {
        let root = tempfile::tempdir().unwrap();
        let api = crate::api::CoreApi::open(root.path()).unwrap();
        let snapshot =
            crate::device_sync::receiver::Snapshot::read(&api.database(), "Local").unwrap();
        let empty = SourceDescriptions::new(&snapshot.manifest, Vec::new()).unwrap();
        let page = empty.pages(&snapshot.manifest).unwrap().remove(0);
        assert!(
            SourceDescriptions::from_pages(vec![page.clone(), page], &snapshot.manifest).is_err()
        );
    }

    #[test]
    fn receiver_source_descriptions_page_and_validate_untrusted_collections() {
        use crate::device_sync::manifest::{AlbumRecord, ManifestRecord};
        let root = tempfile::tempdir().unwrap();
        let api = crate::api::CoreApi::open(root.path()).unwrap();
        let mut manifest = crate::device_sync::receiver::Snapshot::read(&api.database(), "Local")
            .unwrap()
            .manifest;
        let mut entries = Vec::new();
        for index in 1..=130 {
            let source = format!("20000000-0000-4000-8000-{index:012x}");
            manifest.records.push(ManifestRecord::Album(AlbumRecord {
                uuid: format!("30000000-0000-4000-8000-{index:012x}"),
                source_library_uuid: source.clone(),
                name: "Forwarded".into(),
                description: String::new(),
                album_type: "manual".into(),
                pinned: false,
                system_key: None,
                revision: None,
            }));
            entries.push(SourceDescription::new(source, "\u{1f600}".repeat(128)).unwrap());
        }
        let descriptions = SourceDescriptions::new(&manifest, entries).unwrap();
        let pages = descriptions.pages(&manifest).unwrap();
        assert!(pages.len() > 1);
        for page in &pages {
            assert!(page.entries.len() <= 128);
            let json = serde_json::to_vec(page).unwrap();
            assert!(json.len() <= 65_536);
            assert_eq!(SourceDescriptionPage::from_json(&json).unwrap(), *page);
        }
        assert_eq!(
            SourceDescriptions::from_pages(pages.clone(), &manifest).unwrap(),
            descriptions
        );
        let mut repeated = pages.clone();
        repeated.insert(1, repeated[0].clone());
        assert!(SourceDescriptions::from_pages(repeated, &manifest).is_err());
        let mut unrelated = descriptions.clone();
        unrelated.entries.push(
            SourceDescription::new(
                "90000000-0000-4000-8000-000000000001".into(),
                "Unrelated".into(),
            )
            .unwrap(),
        );
        assert!(unrelated.validate(&manifest).is_err());
        let mut duplicate = descriptions.clone();
        duplicate.entries.push(duplicate.entries[0].clone());
        assert!(duplicate.validate(&manifest).is_err());
        let mut wrong = descriptions.clone();
        wrong.manifest_digest = "a".repeat(64);
        assert!(wrong.validate(&manifest).is_err());
        let mut excessive = descriptions.clone();
        excessive
            .entries
            .resize(1025, descriptions.entries[0].clone());
        assert!(excessive.validate(&manifest).is_err());
        assert!(SourceDescriptions::from_json(&vec![b' '; 1024 * 1024 + 1], &manifest).is_err());
        assert!(SourceDescriptionPage::from_json(&vec![b' '; 65_537]).is_err());
        for uuid in [
            "",
            "not-a-uuid",
            "00000000-0000-0000-0000-000000000000",
            "20000000-0000-4000-8000-00000000000A",
        ] {
            assert!(SourceDescription::new(uuid.into(), "Name".into()).is_err());
        }
    }
}
