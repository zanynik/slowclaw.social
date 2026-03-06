import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./styles.css";

type ErrorBoundaryState = {
  errorMessage: string | null;
};

class RootErrorBoundary extends React.Component<React.PropsWithChildren, ErrorBoundaryState> {
  state: ErrorBoundaryState = { errorMessage: null };

  componentDidMount() {
    window.addEventListener("error", this.handleWindowError);
    window.addEventListener("unhandledrejection", this.handleUnhandledRejection);
  }

  componentWillUnmount() {
    window.removeEventListener("error", this.handleWindowError);
    window.removeEventListener("unhandledrejection", this.handleUnhandledRejection);
  }

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { errorMessage: error?.message || "Unknown render error" };
  }

  componentDidCatch(error: Error) {
    this.setState({ errorMessage: error?.stack || error?.message || "Unknown render error" });
  }

  handleWindowError = (event: ErrorEvent) => {
    const details = event.error?.stack || event.message || "Unhandled window error";
    this.setState({ errorMessage: String(details) });
  };

  handleUnhandledRejection = (event: PromiseRejectionEvent) => {
    const reason = event.reason;
    const details =
      (reason && typeof reason === "object" && "stack" in reason && String((reason as any).stack)) ||
      (reason && typeof reason === "object" && "message" in reason && String((reason as any).message)) ||
      String(reason || "Unhandled promise rejection");
    this.setState({ errorMessage: details });
  };

  render() {
    if (this.state.errorMessage) {
      return (
        <main style={{ padding: "1rem", fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace" }}>
          <h1 style={{ marginTop: 0 }}>Frontend Error</h1>
          <p>The app hit a runtime error. Share this message to debug quickly:</p>
          <pre style={{ whiteSpace: "pre-wrap", wordBreak: "break-word" }}>{this.state.errorMessage}</pre>
        </main>
      );
    }
    return this.props.children;
  }
}

ReactDOM.createRoot(document.getElementById("root")!).render(
  <RootErrorBoundary>
    <App />
  </RootErrorBoundary>
);
