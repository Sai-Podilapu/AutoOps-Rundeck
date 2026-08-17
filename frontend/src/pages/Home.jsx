import React from "react";
import Navbar from "../components/Navbar";
import Footer from "../components/Footer";
import Hero from "../sections/Hero";
import OrchestrateMarquee from "../sections/OrchestrateMarquee";
import WorkflowDesigner from "../sections/WorkflowDesigner";
import Observability from "../sections/Observability";
import Capabilities from "../sections/Capabilities";
import Enterprise from "../sections/Enterprise";
import FinalCTA from "../sections/FinalCTA";

export default function Home() {
  return (
    <div className="min-h-screen bg-white text-slate-700">
      <Navbar />
      <main>
        <Hero />
        <OrchestrateMarquee />
        <WorkflowDesigner />
        <Observability />
        <Capabilities />
        <Enterprise />
        <FinalCTA />
      </main>
      <Footer />
    </div>
  );
}
