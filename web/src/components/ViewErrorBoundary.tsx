import React from "react";

type ViewErrorBoundaryProps = React.PropsWithChildren<{
  title: string;
}>;

type ViewErrorBoundaryState = {
  errorMessage: string | null;
};

export class ViewErrorBoundary extends React.Component<
  ViewErrorBoundaryProps,
  ViewErrorBoundaryState
> {
  state: ViewErrorBoundaryState = { errorMessage: null };

  static getDerivedStateFromError(error: Error): ViewErrorBoundaryState {
    return { errorMessage: error?.message || "Unknown view error" };
  }

  componentDidCatch(error: Error) {
    this.setState({
      errorMessage: error?.stack || error?.message || "Unknown view error"
    });
  }

  render() {
    if (this.state.errorMessage) {
      return (
        <div className="card stack">
          <h2 style={{ margin: 0 }}>{this.props.title} failed</h2>
          <p className="text-sm muted" style={{ margin: 0 }}>
            This section hit a runtime error. Refresh the app or switch tabs to recover.
          </p>
          <pre className="workflow-run-detail">{this.state.errorMessage}</pre>
        </div>
      );
    }
    return this.props.children;
  }
}
