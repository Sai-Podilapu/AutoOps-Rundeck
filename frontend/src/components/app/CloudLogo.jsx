import Icon from "../Icon";
import { platformById } from "../../data/saasData";

/**
 * A cloud platform's real logo.
 *
 * saasData stores a PNG filename served from public/assets/Clouds — that is
 * NOT an Icon glyph name, and passing it to <Icon> silently renders the
 * lightning-bolt fallback instead. Every place that shows a platform should
 * use this component so the logo never regresses to a generic glyph.
 *
 * @param platform a platform id/code in any case ("aws", "AWS") or an already
 *                 resolved platform object from saasData
 */
export default function CloudLogo({ platform, size = 24, className = "" }) {
  const pf =
    platform && typeof platform === "object" ? platform : platformById(platform);

  if (pf.icon && pf.icon.endsWith(".png")) {
    return (
      <img
        src={`/assets/Clouds/${pf.icon}`}
        alt={pf.name}
        title={pf.name}
        className={`object-contain ${className}`}
        style={{ width: size, height: size }}
      />
    );
  }
  // Platforms with no bundled logo (Kubernetes) keep their brand colour.
  return (
    <span
      title={pf.name}
      className={`inline-flex items-center justify-center ${className}`}
      style={{ color: pf.color }}
    >
      <Icon name="cloud" size={size} />
    </span>
  );
}
