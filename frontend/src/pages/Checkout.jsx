import React, { useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { LogoMark } from "../components/ui";
import Icon from "../components/Icon";
import { tiers } from "../data/saasData";
import { useStore } from "../store/store";

export default function Checkout() {
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const { login } = useStore();
  const planName = tiers[params.get("plan")] ? params.get("plan") : "Team";
  const plan = tiers[planName];
  const [annual, setAnnual] = useState(true);
  const monthly = plan.price;
  const total = annual ? Math.round(monthly * 12 * 0.8) : monthly;

  const [cardNumber, setCardNumber] = useState("");
  const [expiry, setExpiry] = useState("");
  const [cvc, setCvc] = useState("");

  const handleCardNumber = (e) => {
    let val = e.target.value.replace(/\D/g, "");
    val = val.substring(0, 16);
    let formatted = val.replace(/(\d{4})(?=\d)/g, "$1 ");
    setCardNumber(formatted);
  };

  const getCardType = (num) => {
    if (num.startsWith("4")) return "Visa";
    if (num.startsWith("5")) return "Mastercard";
    if (num.startsWith("3")) return "Amex";
    if (num.startsWith("6")) return "Discover";
    return "";
  };

  const cardType = getCardType(cardNumber.replace(/\D/g, ""));

  const handleExpiry = (e) => {
    let val = e.target.value.replace(/\D/g, "");
    if (val.length >= 1 && parseInt(val[0]) > 1) {
      val = "0" + val;
    }
    if (val.length >= 2) {
      let mm = parseInt(val.substring(0, 2));
      if (mm > 12) mm = 12;
      if (mm === 0 && val.length >= 2) mm = 1;
      let mmStr = mm.toString().padStart(2, "0");
      val = mmStr + val.substring(2);
    }
    val = val.substring(0, 4);
    if (val.length > 2) {
      setExpiry(val.substring(0, 2) + " / " + val.substring(2));
    } else {
      setExpiry(val);
    }
  };

  const handleCvc = (e) => {
    let val = e.target.value.replace(/\D/g, "");
    setCvc(val.substring(0, 4));
  };

  const submit = (e) => {
    e.preventDefault();
    login("client");
    navigate("/onboarding");
  };

  return (
    <div className="grid-bg relative min-h-screen overflow-hidden bg-white px-6 py-12">
      <div className="pointer-events-none absolute inset-0 -z-10">
        <div className="animate-float-glow absolute left-1/2 top-0 h-[420px] w-[620px] -translate-x-1/2 rounded-full bg-emerald-600/12 blur-[150px]" />
      </div>
      <div className="mx-auto max-w-4xl">
        <div className="mb-8 flex items-center justify-between">
          <Link to="/" className="flex items-center gap-2.5">
            <LogoMark size={30} />
          </Link>
          <Link
            to="/signup"
            className="text-sm text-slate-500 transition hover:text-slate-900"
          >
            ← Back
          </Link>
        </div>

        <div className="grid gap-6 lg:grid-cols-5">
          <form
            onSubmit={submit}
            className="animate-fade-up rounded-2xl border border-slate-200 bg-slate-50 p-7 lg:col-span-3"
          >
            <h1 className="text-xl font-semibold text-slate-900">
              Payment details
            </h1>
            <p className="mt-1 text-sm text-slate-500">
              Complete your purchase to activate your {planName} plan.
            </p>
            <div className="mt-6 space-y-4">
              <div>
                <label className="mb-1.5 block text-xs font-medium text-slate-500">
                  Cardholder name
                </label>
                <input
                  required
                  placeholder="Ana Rivera"
                  className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
                />
              </div>
              <div>
                <label className="mb-1.5 block text-xs font-medium text-slate-500">
                  Card number
                </label>
                <div className="relative">
                  <span className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2">
                    {cardType ? (
                      <img
                        src={`/assets/cards/${cardType.toLowerCase()}.png`}
                        alt={cardType}
                        className="h-6 w-auto object-contain drop-shadow-md"
                      />
                    ) : (
                      <Icon name="lock" size={15} className="text-slate-600" />
                    )}
                  </span>
                  <input
                    required
                    value={cardNumber}
                    onChange={handleCardNumber}
                    placeholder="4242 4242 4242 4242"
                    className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
                  />
                </div>
              </div>
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="mb-1.5 block text-xs font-medium text-slate-500">
                    Expiry
                  </label>
                  <input
                    required
                    value={expiry}
                    onChange={handleExpiry}
                    placeholder="MM / YY"
                    className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
                  />
                </div>
                <div>
                  <label className="mb-1.5 block text-xs font-medium text-slate-500">
                    CVC
                  </label>
                  <input
                    required
                    value={cvc}
                    onChange={handleCvc}
                    placeholder="123"
                    className="w-full rounded-lg border border-slate-200 bg-slate-50 px-4 py-2.5 text-sm text-slate-900 outline-none transition focus:border-slate-300 focus:ring-2 focus:ring-slate-300"
                  />
                </div>
              </div>
            </div>
            <button
              type="submit"
              className="mt-6 flex w-full items-center justify-center gap-2 rounded-lg bg-slate-900 px-6 py-3 text-sm font-semibold text-white shadow-lg shadow-slate-300/40 transition hover:brightness-110"
            >
              <Icon name="check" size={16} /> Subscribe to {planName}
            </button>
            <p className="mt-3 flex items-center justify-center gap-1.5 text-[11px] text-slate-600">
              <Icon name="shield" size={12} /> Secured with 256-bit encryption ·
              cancel anytime
            </p>
          </form>

          <div className="animate-fade-up rounded-2xl border border-slate-200 bg-slate-50 p-7 lg:col-span-2">
            <h2 className="text-sm font-semibold text-slate-900">
              Order summary
            </h2>
            <div className="mt-4 flex items-center justify-between rounded-xl border border-slate-300 bg-slate-100 px-4 py-3">
              <div>
                <p className="text-sm font-semibold text-slate-900">
                  {planName} plan
                </p>
                <p className="text-xs text-slate-500">
                  {plan.automations === "Unlimited"
                    ? "Unlimited"
                    : plan.automations}{" "}
                  automations / mo
                </p>
              </div>
              <p className="text-lg font-bold text-slate-900">
                ${monthly}
                <span className="text-xs font-normal text-slate-500">/mo</span>
              </p>
            </div>
            <div className="mt-4 flex items-center justify-between rounded-lg border border-slate-200 bg-slate-50 px-4 py-3">
              <div>
                <p className="text-sm text-slate-700">Bill annually</p>
                <p className="text-xs text-emerald-600">Save 20%</p>
              </div>
              <button
                type="button"
                onClick={() => setAnnual((v) => !v)}
                className={`relative inline-flex h-6 w-11 items-center rounded-full transition ${annual ? "bg-gradient-to-r from-slate-900 to-slate-900" : "bg-slate-50"}`}
              >
                <span
                  className={`inline-block h-4 w-4 transform rounded-full bg-white transition ${annual ? "translate-x-6" : "translate-x-1"}`}
                />
              </button>
            </div>
            <div className="mt-5 space-y-2 border-t border-slate-200 pt-4 text-sm">
              <div className="flex justify-between text-slate-500">
                <span>Subtotal</span>
                <span>${annual ? monthly * 12 : monthly}.00</span>
              </div>
              {annual && (
                <div className="flex justify-between text-emerald-600">
                  <span>Annual discount</span>
                  <span>-${monthly * 12 - total}.00</span>
                </div>
              )}
              <div className="flex justify-between text-base font-semibold text-slate-900">
                <span>Due today</span>
                <span>${total}.00</span>
              </div>
              <p className="text-[11px] text-slate-500">
                Renews automatically. Cancel anytime.
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
