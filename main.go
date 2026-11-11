// oidc-device-login-federated: OIDC Device Authorization Grant where the
// client authenticates with a federated JWT (GitLab CI id_token) instead of
// a client secret. The resulting Access Token proves both that the request
// comes from the allowed CI job (azp) and that a user approved it (sub).
package main

import (
	"context"
	"fmt"
	"log"
	"os"

	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/spf13/cobra"
	"golang.org/x/oauth2"
)

const clientAssertionType = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

var FlagIssuer string
var FlagClientID string
var FlagClientAssertion string
var FlagClientAssertionEnv string

var Cmd = &cobra.Command{
	Use:   "oidc-device-login-federated",
	Short: "OIDC Device Authorization Grant login with federated client assertion, prints Access Token to stdout",
	Args:  cobra.NoArgs,
	Run: func(c *cobra.Command, args []string) {
		clientAssertion := FlagClientAssertion
		if FlagClientAssertionEnv != "" {
			clientAssertion = os.Getenv(FlagClientAssertionEnv)
			if clientAssertion == "" {
				log.Fatalf("Env variable %s with client assertion (JWT) is empty", FlagClientAssertionEnv)
			}
		}
		oidcDeviceLoginFederated(FlagIssuer, FlagClientID, clientAssertion)
	},
}

func init() {
	Cmd.Flags().StringVar(&FlagIssuer, "issuer", "", "Issuer")
	Cmd.MarkFlagRequired("issuer")
	Cmd.Flags().StringVar(&FlagClientID, "client-id", "", "Client ID")
	Cmd.MarkFlagRequired("client-id")
	Cmd.Flags().StringVar(&FlagClientAssertion, "client-assertion", "", "Client assertion (JWT), e.g. GitLab CI id_token")
	// Read from env so the JWT is not visible in the process list
	Cmd.Flags().StringVar(&FlagClientAssertionEnv, "client-assertion-env", "", "Env variable with client assertion (JWT), e.g. KC_JWT")
	Cmd.MarkFlagsMutuallyExclusive("client-assertion", "client-assertion-env")
	Cmd.MarkFlagsOneRequired("client-assertion", "client-assertion-env")
}

func main() {
	if err := Cmd.Execute(); err != nil {
		os.Exit(1)
	}
}

func oidcDeviceLoginFederated(issuer, clientID, clientAssertion string) {
	ctx := context.Background()

	provider, err := oidc.NewProvider(ctx, issuer)
	if err != nil {
		log.Fatal(err)
	}

	endpoint := provider.Endpoint()
	// No client secret, send client_id in the body, never as Basic auth
	endpoint.AuthStyle = oauth2.AuthStyleInParams

	config := oauth2.Config{
		ClientID: clientID,
		Endpoint: endpoint,
		Scopes:   []string{oidc.ScopeOpenID},
	}

	// Client authentication on both device and token requests.
	// The same JWT is sent on every poll, so the Keycloak IdP must allow
	// client assertion reuse.
	assertion := []oauth2.AuthCodeOption{
		oauth2.SetAuthURLParam("client_assertion_type", clientAssertionType),
		oauth2.SetAuthURLParam("client_assertion", clientAssertion),
	}

	deviceAuth, err := config.DeviceAuth(ctx, assertion...)
	if err != nil {
		log.Fatal(err)
	}

	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "==================================================")
	if jobURL := ciJobURL(); jobURL != "" {
		fmt.Fprintln(os.Stderr, "Approval required for job:", jobURL)
	}
	fmt.Fprintln(os.Stderr, "Open in browser:", deviceAuth.VerificationURIComplete)
	fmt.Fprintln(os.Stderr, "Or open:        ", deviceAuth.VerificationURI)
	fmt.Fprintln(os.Stderr, "and enter code: ", deviceAuth.UserCode)
	fmt.Fprintln(os.Stderr, "==================================================")
	fmt.Fprintln(os.Stderr)

	// Polls the token endpoint until the user approves (or denies)
	// the login or the code expires
	oauth2Token, err := config.DeviceAccessToken(ctx, deviceAuth, assertion...)
	if err != nil {
		log.Fatal(err)
	}

	// Keycloak Access Token has "aud": "account" unless an audience mapper
	// for this client is configured, so skip the client ID (audience) check
	accessToken, err := provider.Verifier(&oidc.Config{SkipClientIDCheck: true}).Verify(ctx, oauth2Token.AccessToken)
	if err != nil {
		log.Fatal("Failed to verify Access Token: " + err.Error())
	}

	var claims struct {
		Sub               string `json:"sub"`
		PreferredUsername string `json:"preferred_username"`
		Email             string `json:"email"`
		Azp               string `json:"azp"`
	}
	if err := accessToken.Claims(&claims); err != nil {
		log.Fatal(err)
	}
	if claims.Azp != clientID {
		log.Fatalf("Access Token azp is %q, expected %q", claims.Azp, clientID)
	}

	fmt.Fprintf(os.Stderr, "Approved by %s (sub=%s email=%s), azp=%s\n", claims.PreferredUsername, claims.Sub, claims.Email, claims.Azp)

	fmt.Println(oauth2Token.AccessToken)
}

// ciJobURL returns the URL of the current CI job (GitLab CI or GitHub Actions)
func ciJobURL() string {
	if url := os.Getenv("CI_JOB_URL"); url != "" {
		return url
	}
	if os.Getenv("GITHUB_RUN_ID") != "" {
		return os.Getenv("GITHUB_SERVER_URL") + "/" + os.Getenv("GITHUB_REPOSITORY") + "/actions/runs/" + os.Getenv("GITHUB_RUN_ID")
	}
	return ""
}
