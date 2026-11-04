use super::*;

// Wrong allocation, metadata multiplier, grouping or margin changes these literals.
#[test]
fn literal_peak_budgets_cover_cache_and_volume_layouts() {
    for (missing, publishing, ids, expected) in [
        (
            vec![3],
            vec![3],
            [1, 1, 1],
            vec![(16_958_640, 67_108_864, 84_067_504)],
        ),
        (
            vec![],
            vec![3],
            [1, 1, 1],
            vec![(16_876_720, 67_108_864, 83_985_584)],
        ),
        (
            vec![],
            vec![],
            [1, 1, 1],
            vec![(16_794_800, 67_108_864, 83_903_664)],
        ),
        (
            vec![3],
            vec![3],
            [1, 2, 2],
            vec![
                (81_920, 67_108_864, 67_190_784),
                (16_876_720, 67_108_864, 83_985_584),
            ],
        ),
        (
            vec![3],
            vec![3],
            [1, 2, 3],
            vec![
                (81_920, 67_108_864, 67_190_784),
                (81_920, 67_108_864, 67_190_784),
                (16_794_800, 67_108_864, 83_903_664),
            ],
        ),
        (
            vec![65_537],
            vec![3, 65_537],
            [1, 1, 1],
            vec![(17_171_632, 67_108_864, 84_280_496)],
        ),
    ] {
        let costs = costs(&missing, &publishing, 4096, 100, 200).unwrap();
        let view = calculate(
            costs,
            [(ids[0], u64::MAX), (ids[1], u64::MAX), (ids[2], u64::MAX)],
        )
        .unwrap();
        assert_eq!(
            view.volumes
                .iter()
                .map(|v| (v.additional_bytes, v.safety_margin_bytes, v.required_bytes))
                .collect::<Vec<_>>(),
            expected
        );
        assert!(view.includes_metadata && view.includes_allocation_estimate);
    }
}

#[test]
fn admission_exact_boundary_and_same_volume_uses_lowest_free_sample() {
    let costs = costs(&[3], &[3], 4096, 100, 200).unwrap();
    assert!(calculate(costs, [(7, 84_067_504); 3]).is_ok());
    assert_eq!(
        calculate(costs, [(7, 84_067_504), (7, 84_067_503), (7, u64::MAX)]),
        Err(StagingError::InsufficientSpace)
    );
    let view = calculate([0, 0, 1], [(1, 0), (2, 0), (3, u64::MAX)]).unwrap();
    assert_eq!(
        view.volumes.len(),
        1,
        "unused independent volumes are not charged"
    );
}

#[test]
fn fixed_and_five_percent_margin_boundary_and_checked_overflow() {
    for (base, margin, required) in [
        (1_342_177_280, 67_108_864, 1_409_286_144),
        (1_342_177_281, 67_108_865, 1_409_286_146),
    ] {
        let view = calculate([base, 0, 0], [(1, u64::MAX); 3]).unwrap();
        assert_eq!(
            (
                view.volumes[0].safety_margin_bytes,
                view.volumes[0].required_bytes
            ),
            (margin, required)
        );
    }
    assert_eq!(allocation(u64::MAX), Err(StagingError::Overflow));
    assert_eq!(costs(&[], &[], u64::MAX, 1, 0), Err(StagingError::Overflow));
    assert_eq!(
        calculate([u64::MAX, 1, 0], [(1, u64::MAX); 3]),
        Err(StagingError::Overflow)
    );
    assert_eq!(
        calculate([u64::MAX, 0, 0], [(1, u64::MAX); 3]),
        Err(StagingError::Overflow)
    );
}

#[test]
fn real_directories_group_by_volume_not_path_and_reject_missing_and_links() {
    let root = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
    let a = root.path().join("a");
    let b = root.path().join("b");
    std::fs::create_dir(&a).unwrap();
    std::fs::create_dir(&b).unwrap();
    let a = DirectorySample::open(&a).unwrap();
    let b = DirectorySample::open(&b).unwrap();
    assert_eq!(a.volume, b.volume);
    assert!(DirectorySample::open(&root.path().join("missing")).is_err());
    let link = root.path().join("link");
    #[cfg(windows)]
    std::os::windows::fs::symlink_dir(b.directory.path(), &link).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(b.directory.path(), &link).unwrap();
    assert!(DirectorySample::open(&link).is_err());
}

#[test]
fn same_volume_mount_alias_probe_merges_all_three_real_paths() {
    let root = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
    let paths = ["stage", "originals", "database"].map(|p| root.path().join(p));
    for path in &paths {
        std::fs::create_dir(path).unwrap();
    }
    // Only OS volume ID/free sampling is replaced. Directory validation and
    // the production calculator remain real; no mount point is created.
    let view = measure_paths(
        &paths[0],
        &paths[1],
        &paths[2],
        [81_920, 81_920, 16_794_800],
        |sample| {
            sample.volume = 42;
            Ok(84_067_504)
        },
    )
    .unwrap();
    assert_eq!(view.volumes.len(), 1);
    assert_eq!(view.volumes[0].required_bytes, 84_067_504);
    assert_eq!(
        view.volumes[0].roles,
        vec![
            StorageRole::Staging,
            StorageRole::Originals,
            StorageRole::Database
        ]
    );
    assert_eq!(
        measure_paths(&paths[0], &paths[1], &paths[2], [0, 0, 1], |_| Err(
            StagingError::Read
        )),
        Err(StagingError::Read)
    );
}
