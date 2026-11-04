import 'package:flutter/material.dart';

import '../app_branding.dart';
import 'font_families.dart';

class AppBrandTitle extends StatelessWidget {
  const AppBrandTitle({
    super.key,
    required this.text,
    this.textKey,
    this.underlineKey,
    this.color,
  });

  final String text;
  final Key? textKey;
  final Key? underlineKey;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final chineseBrand = text == appChineseName;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          key: textKey,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: chineseBrand ? appBrandFontFamily : appFontFamily,
            fontFamilyFallback: chineseBrand
                ? appBrandFontFallback
                : appFontFallback,
            color: color,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (chineseBrand) ...[
          const SizedBox(height: 2),
          DecoratedBox(
            key: underlineKey,
            decoration: const BoxDecoration(
              color: Color(0xffffc107),
              borderRadius: BorderRadius.all(Radius.circular(2)),
            ),
            child: const SizedBox(width: 40, height: 3),
          ),
        ],
      ],
    );
  }
}
