import React from "react";

// Colored brand logos served from /public/assets. White tile keeps every
// logo vivid and legible on the dark background.
const TARGETS = [
  { name: "AWS", img: "/assets/Clouds/AWS.png" },
  { name: "Azure", img: "/assets/Clouds/Azure.png" },
  { name: "Google Cloud", img: "/assets/Clouds/GCP.png" },
  { name: "OCI", img: "/assets/Clouds/OCI.png" },
  { name: "Huawei Cloud", img: "/assets/Clouds/Huawei-Logo.png" },
  { name: "Microsoft 365", img: "/assets/Clouds/M365.png" },
  { name: "Kubernetes", img: "/assets/Icons/Kubernetes.png" },
  { name: "Docker", img: "/assets/Icons/Docker.png" },
  { name: "Terraform", img: "/assets/Icons/Terraform.png" },
  { name: "SSH", img: "/assets/Icons/SSH.png" },
  { name: "HashiCorp Vault", img: "/assets/Icons/Hashicorp.png" },
  { name: "GitHub", img: "/assets/Icons/Github.png" },
  { name: "Linux", img: "/assets/Icons/Linux.png" },
];

function Chip({ name, img }) {
  return (
    <div className="group mx-3 flex shrink-0 items-center gap-4 rounded-2xl border border-slate-200 bg-slate-50 px-7 py-5 transition duration-300 hover:-translate-y-1 hover:border-blue-500 hover:bg-slate-100">
      <span className="flex h-12 w-12 items-center justify-center transition group-hover:scale-110">
        <img
          src={img}
          alt={`${name} logo`}
          className="h-full w-full object-contain drop-shadow-md"
          loading="lazy"
        />
      </span>
      <span className="whitespace-nowrap text-base font-semibold text-slate-600 transition group-hover:text-slate-900">
        {name}
      </span>
    </div>
  );
}

export default function OrchestrateMarquee() {
  const row = [...TARGETS, ...TARGETS];
  return (
    <section className="py-16">
      <p className="text-center text-xs font-semibold uppercase tracking-[0.25em] text-slate-500">
        Orchestrate across every target
      </p>
      <div className="marquee mt-10">
        <div className="marquee-track py-1">
          {row.map((t, i) => (
            <Chip key={i} {...t} />
          ))}
        </div>
      </div>
    </section>
  );
}
